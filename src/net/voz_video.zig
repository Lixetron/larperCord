//! Vídeo recebido na call: quem está transmitindo, o que a interface quer
//! assistir e a thread que decodifica o H.264 em RGBA.
//!
//! Vários streams ao mesmo tempo (até `max_watch`), cada um com o seu
//! decodificador e o seu último quadro. O tamanho do quadro é o da área onde
//! ele aparece: numa grade, cada tile decodifica no tamanho do tile — o custo
//! de CPU e de memória fica proporcional ao que está na tela, não ao 1440p da
//! fonte.
//!
//! Não há fila de quadros prontos: mostra o mais novo, e um quadro velho não
//! atrasa o próximo. Sem FFmpeg (ou com uma versão que o app não conhece) o
//! vídeo não abre: o `Status` diz à interface para explicar, como já acontece
//! com os anexos.
const std = @import("std");
const c = @import("c");
const sys = @import("../platform/sys.zig");
const ffmpeg = @import("../platform/ffmpeg.zig");
const types = @import("../core/types.zig");
const frame_stats = @import("../core/frame_stats.zig");
const nowMs = @import("fake_gateway.zig").nowMs;

const Id = types.Id;
const alloc = std.heap.c_allocator;

pub const max_streams = 16;
pub const Stream = struct {
    user: Id = 0,
    ssrc: u32 = 0,
    rtx: u32 = 0,
    active: bool = false,
};

pub const Status = enum(u8) {
    /// Ninguém assistindo.
    idle,
    /// Escolhemos alguém e ainda não chegou quadro.
    starting,
    playing,
    /// O FFmpeg não abriu o decodificador H.264.
    no_codec,
    /// Chegou quadro quebrado (perda): esperando o próximo quadro-chave.
    stalled,
};

/// De onde vem o vídeo: a câmera na conexão de voz ou um Go Live (conexão de
/// stream separada). Cada Worker só mexe no que é dele.
pub const Source = enum(u8) { voice = 1, stream = 2 };

/// Até onde o quadro é reduzido para a tela (1080p cabe inteiro; acima disso
/// o swscale reduz). O teto evita memória/CPU demais num stream 4K.
pub const max_w = 1920;
pub const max_h: u32 = 1080;

/// Quantos streams a interface pode assistir ao mesmo tempo (grade da call).
pub const max_watch = 4;
const max_frame: usize = 8 << 20;
const queue_n = max_watch * 3;

/// O que a interface quer ver: quem, de onde e em que tamanho.
pub const WatchReq = struct { user: Id, src: Source, ssrc: u32, w: u32 = 0, h: u32 = 0 };

/// Cópia da escolha para a interface desenhar a grade.
pub const WatchInfo = struct { user: Id, src: Source, ssrc: u32 };

const Watch = struct {
    user: Id = 0,
    ssrc: u32 = 0,
    src: Source = .voice,
    view_w: u32 = 0,
    view_h: u32 = 0,
    /// Último quadro em RGBA (protegido por `lock`).
    px: []u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    gen: u32 = 0,
};

const Slot = struct { buf: []u8 = &.{}, len: usize = 0, ssrc: u32 = 0 };

/// Protege a fila, a tabela de streams, a escolha e os quadros prontos. Um
/// mutex só: a interface segura por poucos microssegundos, durante o upload da
/// textura, e isso não atrapalha o recebimento.
var lock: ?*c.SDL_Mutex = null;
var cond: ?*c.SDL_Condition = null;
var thread: ?*c.SDL_Thread = null;
var stopping = false;

var watches: [max_watch]Watch = @splat(.{});
var n_watch: usize = 0;
/// Quem a interface abriu por cima da grade (0 = grade).
var focus_user: sys.Atomic(Id) = .init(0);
var focus_src: sys.Atomic(u8) = .init(0);

var streams: [max_streams]Stream = @splat(.{});
var n_streams: usize = 0;

/// Quantos Workers (voz e/ou stream) estão usando o hub.
var refs: sys.Atomic(u32) = .init(0);

/// Resolução do último quadro que chegou (antes de reduzir para o tile).
var src_w: sys.Atomic(u32) = .init(0);
var src_h: sys.Atomic(u32) = .init(0);

var queue: [queue_n]Slot = @splat(.{});
var q_head: usize = 0;
var q_len: usize = 0;

var status_now: sys.Atomic(u8) = .init(@intFromEnum(Status.idle));
var last_frame_ms: sys.Atomic(i64) = .init(0);
var frames_now: sys.Atomic(u64) = .init(0);
var shown_now: sys.Atomic(u64) = .init(0);
var bytes_now: sys.Atomic(u64) = .init(0);
var unique_now: sys.Atomic(u64) = .init(0);
var drops_now: sys.Atomic(u64) = .init(0);
/// Movimento médio entre o quadro atual e o anterior (0..255 de luma).
var motion_now: sys.Atomic(u32) = .init(0);
/// Demonstração/QA: em vez de decodificar, desenha um gradiente animado.
/// Sem FFmpeg e sem rede, mas passa pela textura e pela janela de verdade.
var pattern_on: sys.Atomic(bool) = .init(false);

pub fn setPattern(on: bool) void {
    pattern_on.store(on, .release);
    wake();
}

/// Acorda a decodificação: ela pode estar dormindo esperando o primeiro quadro
/// justamente quando a escolha do que assistir (ou o modo de teste) muda.
fn wake() void {
    const m = lock orelse return;
    c.SDL_LockMutex(m);
    if (cond) |cd| c.SDL_BroadcastCondition(cd);
    c.SDL_UnlockMutex(m);
}

/// Os mutexes e a condição vivem até o processo acabar: a interface pode estar
/// lendo o quadro quando a call termina, e destruir o mutex embaixo dela seria
/// uma corrida. São dois objetos pequenos, criados na primeira call.
fn ensureLocks() bool {
    if (lock == null) lock = c.SDL_CreateMutex();
    if (cond == null) cond = c.SDL_CreateCondition();
    return lock != null and cond != null;
}

/// Cada Worker (voz, stream) segura uma referência. A thread de decodificação
/// nasce na primeira e só morre quando a última solta.
pub fn start() void {
    if (sys.web) return;
    if (refs.fetchAdd(1, .acq_rel) != 0) return;
    if (!ensureLocks()) {
        refs.store(0, .release);
        return;
    }
    stopping = false;
    q_head = 0;
    q_len = 0;
    // A escolha de quem assistir pode ter sido feita antes de a thread nascer
    // (a interface não espera a call terminar de abrir): não zera aqui.
    status_now.store(@intFromEnum(Status.idle), .release);
    if (c.SDL_CreateThread(decodeMain, "voz-video", null)) |t| {
        thread = t;
    } else {
        stopping = true;
        refs.store(0, .release);
    }
}

/// Solta uma referência; a última desmonta tudo.
pub fn stop() void {
    const r = refs.fetchSub(1, .acq_rel);
    if (r == 0) {
        // stop sem start correspondente (ou já desmontado).
        refs.store(0, .release);
        return;
    }
    if (r > 1) return;
    if (thread) |t| {
        c.SDL_LockMutex(lock.?);
        stopping = true;
        c.SDL_BroadcastCondition(cond.?);
        c.SDL_UnlockMutex(lock.?);
        c.SDL_WaitThread(t, null);
        thread = null;
    }
    stopping = true;
    // Nada mais decodifica: a fila pode ir embora.
    for (&queue) |*s| if (s.buf.len > 0) {
        alloc.free(s.buf);
        s.* = .{};
    };
    q_head = 0;
    q_len = 0;
    n_streams = 0;
    for (watches[0..n_watch]) |*wv| {
        if (wv.px.len > 0) alloc.free(wv.px);
        wv.* = .{};
    }
    n_watch = 0;
    focus_user.store(0, .release);
    focus_src.store(0, .release);
    frames_now.store(0, .release);
    shown_now.store(0, .release);
    bytes_now.store(0, .release);
    unique_now.store(0, .release);
    drops_now.store(0, .release);
    motion_now.store(0, .release);
    last_frame_ms.store(0, .release);
    status_now.store(@intFromEnum(Status.idle), .release);
}

// --- Tabela de streams (op 12) ---------------------------------------------

pub fn clearStreams() void {
    const m = lock;
    if (m) |x| c.SDL_LockMutex(x);
    n_streams = 0;
    if (m) |x| c.SDL_UnlockMutex(x);
}

/// Atualiza (ou acrescenta) o vídeo de alguém. `active=false` só desliga.
pub fn setStream(user: Id, ssrc: u32, rtx: u32, active: bool) void {
    if (user == 0) return;
    const m = lock;
    if (m) |x| c.SDL_LockMutex(x);
    defer {
        if (m) |x| c.SDL_UnlockMutex(x);
    }
    for (streams[0..n_streams]) |*s| {
        if (s.user != user) continue;
        if (ssrc != 0) s.ssrc = ssrc;
        if (rtx != 0) s.rtx = rtx;
        s.active = active;
        return;
    }
    if (n_streams == max_streams) return;
    streams[n_streams] = .{ .user = user, .ssrc = ssrc, .rtx = rtx, .active = active };
    n_streams += 1;
}

pub fn removeUser(user: Id) void {
    const m = lock;
    if (m) |x| c.SDL_LockMutex(x);
    defer {
        if (m) |x| c.SDL_UnlockMutex(x);
    }
    var i: usize = 0;
    while (i < n_streams) : (i += 1) {
        if (streams[i].user != user) continue;
        var k = i;
        while (k + 1 < n_streams) : (k += 1) streams[k] = streams[k + 1];
        n_streams -= 1;
        return;
    }
}

/// Cópia da tabela para a interface (fora do mutex).
pub fn copyStreams(out: *[max_streams]Stream) usize {
    const m = lock;
    if (m) |x| c.SDL_LockMutex(x);
    defer {
        if (m) |x| c.SDL_UnlockMutex(x);
    }
    @memcpy(out[0..n_streams], streams[0..n_streams]);
    return n_streams;
}

/// Quantos estão transmitindo agora.
pub fn activeCount() usize {
    const m = lock;
    if (m) |x| c.SDL_LockMutex(x);
    defer {
        if (m) |x| c.SDL_UnlockMutex(x);
    }
    var n: usize = 0;
    for (streams[0..n_streams]) |s| if (s.active and s.ssrc != 0) {
        n += 1;
    };
    return n;
}

/// O stream (SSRC) de alguém, se estiver ativo.
pub fn ssrcOf(user: Id) u32 {
    const m = lock;
    if (m) |x| c.SDL_LockMutex(x);
    defer {
        if (m) |x| c.SDL_UnlockMutex(x);
    }
    for (streams[0..n_streams]) |s| if (s.user == user and s.active) return s.ssrc;
    return 0;
}

// --- Escolha do que assistir -------------------------------------------------

/// A interface manda a lista inteira do que quer ver (grade da call). Mantém o
/// estado de quem continua na lista; libera o quadro de quem saiu.
pub fn setWatches(reqs: []const WatchReq) void {
    const m = lock orelse return;
    c.SDL_LockMutex(m);
    defer c.SDL_UnlockMutex(m);
    // A interface chama a cada quadro: se só o tamanho do tile mexeu, ajusta
    // sem refazer a lista (e sem acordar a decodificação à toa).
    var same = reqs.len == n_watch;
    if (same) {
        for (reqs, 0..) |r, i| {
            const wv = watches[i];
            if (wv.ssrc != r.ssrc or wv.user != r.user or wv.src != r.src) {
                same = false;
                break;
            }
        }
    }
    if (same) {
        for (reqs, 0..) |r, i| {
            watches[i].view_w = r.w;
            watches[i].view_h = r.h;
        }
        return;
    }
    var old: [max_watch]Watch = watches;
    const old_n = n_watch;
    n_watch = 0;
    for (reqs) |r| {
        if (n_watch == max_watch) break;
        if (r.user == 0 or r.ssrc == 0) continue;
        var wv: Watch = .{ .user = r.user, .src = r.src, .ssrc = r.ssrc, .view_w = r.w, .view_h = r.h };
        for (old[0..old_n]) |o| {
            if (o.ssrc != r.ssrc) continue;
            wv = o;
            wv.user = r.user;
            wv.src = r.src;
            wv.view_w = r.w;
            wv.view_h = r.h;
            break;
        }
        watches[n_watch] = wv;
        n_watch += 1;
    }
    for (old[0..old_n]) |o| {
        if (o.px.len == 0) continue;
        var kept = false;
        for (watches[0..n_watch]) |nw| if (nw.ssrc == o.ssrc) {
            kept = true;
            break;
        };
        if (!kept) alloc.free(o.px);
    }
    status_now.store(@intFromEnum(if (n_watch == 0) Status.idle else Status.starting), .release);
    if (cond) |cd| c.SDL_BroadcastCondition(cd);
}

/// Cópia do que está sendo assistido (grade).
pub fn copyWatches(out: *[max_watch]WatchInfo) usize {
    const m = lock;
    if (m) |x| c.SDL_LockMutex(x);
    defer {
        if (m) |x| c.SDL_UnlockMutex(x);
    }
    for (watches[0..n_watch], 0..) |wv, i| out[i] = .{ .user = wv.user, .src = wv.src, .ssrc = wv.ssrc };
    return n_watch;
}

/// Os SSRCs assistidos de um tipo de conexão (o Worker dono pede ao servidor).
pub fn watchSsrcs(src: Source, out: *[max_watch]u32) []u32 {
    const m = lock;
    if (m) |x| c.SDL_LockMutex(x);
    defer {
        if (m) |x| c.SDL_UnlockMutex(x);
    }
    var n: usize = 0;
    for (watches[0..n_watch]) |wv| {
        if (wv.src != src or wv.ssrc == 0) continue;
        out[n] = wv.ssrc;
        n += 1;
    }
    return out[0..n];
}

pub fn isWatched(ssrc: u32) bool {
    if (ssrc == 0) return false;
    const m = lock;
    if (m) |x| c.SDL_LockMutex(x);
    defer {
        if (m) |x| c.SDL_UnlockMutex(x);
    }
    for (watches[0..n_watch]) |wv| if (wv.ssrc == ssrc) return true;
    return false;
}

pub fn watching() Id {
    return focus_user.load(.acquire);
}

pub fn watchSource() ?Source {
    return switch (focus_src.load(.acquire)) {
        1 => .voice,
        2 => .stream,
        else => null,
    };
}

/// A interface escolheu uma pessoa (o visualizador de um stream só). 0 fecha.
pub fn watch(user: Id, src: Source) void {
    focus_user.store(user, .release);
    focus_src.store(if (user == 0) 0 else @intFromEnum(src), .release);
    if (user == 0) {
        setWatches(&.{});
        return;
    }
    const ssrc = ssrcOf(user);
    var one: [1]WatchReq = .{.{ .user = user, .src = src, .ssrc = ssrc }};
    setWatches(one[0..]);
}

/// A interface diz o tamanho da área onde o vídeo (focado) aparece.
pub fn setView(w: u32, h: u32) void {
    const m = lock orelse return;
    c.SDL_LockMutex(m);
    defer c.SDL_UnlockMutex(m);
    const user = focus_user.load(.acquire);
    for (watches[0..n_watch]) |*wv| {
        if (user != 0 and wv.user != user) continue;
        wv.view_w = w;
        wv.view_h = h;
        return;
    }
}

/// Tamanho pedido para um SSRC (a grade usa um por tile).
pub fn setViewFor(ssrc: u32, w: u32, h: u32) void {
    const m = lock orelse return;
    c.SDL_LockMutex(m);
    defer c.SDL_UnlockMutex(m);
    for (watches[0..n_watch]) |*wv| {
        if (wv.ssrc != ssrc) continue;
        wv.view_w = w;
        wv.view_h = h;
        return;
    }
}

pub fn sourceSize() [2]u32 {
    return .{ src_w.load(.acquire), src_h.load(.acquire) };
}

// --- Quadros --------------------------------------------------------------

/// A thread de voz entrega um quadro H.264 inteiro. Só entra o que a interface
/// quer ver; os outros nem são copiados.
pub fn push(ssrc: u32, bytes: []const u8) void {
    const m = lock orelse return;
    if (ssrc == 0 or bytes.len == 0 or bytes.len > max_frame) return;
    c.SDL_LockMutex(m);
    defer c.SDL_UnlockMutex(m);
    var wanted = false;
    for (watches[0..n_watch]) |wv| if (wv.ssrc == ssrc) {
        wanted = true;
        break;
    };
    if (!wanted) return;
    if (q_len == queue_n) {
        // A decodificação está atrás: fica com o quadro novo.
        q_head = (q_head + 1) % queue_n;
        q_len -= 1;
        _ = drops_now.fetchAdd(1, .monotonic);
    }
    const idx = (q_head + q_len) % queue_n;
    const slot = &queue[idx];
    if (slot.buf.len < bytes.len) {
        const nb = alloc.realloc(slot.buf, bytes.len) catch return;
        slot.buf = nb;
    }
    @memcpy(slot.buf[0..bytes.len], bytes);
    slot.len = bytes.len;
    slot.ssrc = ssrc;
    q_len += 1;
    if (cond) |cd| c.SDL_BroadcastCondition(cd);
}

/// O último quadro em RGBA do SSRC, travado para o upload da textura. Quem
/// chama precisa de `unlockFrame`, mesmo se devolver null.
pub const View = struct { px: []const u8, w: u32, h: u32, gen: u32, ssrc: u32, user: Id };

pub fn lockFrameOf(ssrc: u32) ?View {
    const m = lock orelse return null;
    c.SDL_LockMutex(m);
    for (watches[0..n_watch]) |wv| {
        if (wv.ssrc != ssrc or wv.w == 0 or wv.h == 0 or wv.px.len == 0) continue;
        return .{
            .px = wv.px[0..ffmpeg.rgbaSize(wv.w, wv.h)],
            .w = wv.w,
            .h = wv.h,
            .gen = wv.gen,
            .ssrc = wv.ssrc,
            .user = wv.user,
        };
    }
    c.SDL_UnlockMutex(m);
    return null;
}

/// Quadro do stream em foco (visualizador de um só).
pub fn lockFrame() ?View {
    const m = lock orelse return null;
    c.SDL_LockMutex(m);
    const user = focus_user.load(.acquire);
    for (watches[0..n_watch]) |wv| {
        if (user != 0 and wv.user != user) continue;
        if (wv.w == 0 or wv.h == 0 or wv.px.len == 0) continue;
        return .{
            .px = wv.px[0..ffmpeg.rgbaSize(wv.w, wv.h)],
            .w = wv.w,
            .h = wv.h,
            .gen = wv.gen,
            .ssrc = wv.ssrc,
            .user = wv.user,
        };
    }
    c.SDL_UnlockMutex(m);
    return null;
}

pub fn unlockFrame() void {
    if (lock) |m| c.SDL_UnlockMutex(m);
}

pub fn status() Status {
    return @enumFromInt(status_now.load(.acquire));
}

/// Há quanto tempo o último quadro chegou (ms); -1 = nunca.
pub fn sinceFrameMs() i64 {
    const t = last_frame_ms.load(.acquire);
    if (t == 0) return -1;
    return nowMs() - t;
}

pub const Stats = struct { frames: u64, shown: u64, unique: u64, bytes: u64, drops: u64, motion: u32 };
pub fn stats() Stats {
    return .{
        .frames = frames_now.load(.monotonic),
        .shown = shown_now.load(.monotonic),
        .unique = unique_now.load(.monotonic),
        .bytes = bytes_now.load(.monotonic),
        .drops = drops_now.load(.monotonic),
        .motion = motion_now.load(.monotonic),
    };
}

/// A interface chama depois de subir um quadro para a textura: é o fps que a
/// pessoa realmente vê (o `frames` é o que o decodificador produziu).
pub fn noteShown() void {
    _ = shown_now.fetchAdd(1, .monotonic);
}

/// Bytes de vídeo que chegaram (para o Mbps mostrado no canto).
pub fn noteBytes(n: usize) void {
    _ = bytes_now.fetchAdd(n, .monotonic);
}

// --- Decodificação ---------------------------------------------------------

/// Um decodificador por stream assistido, com o estado do hash/movimento.
const Dec = struct {
    ssrc: u32 = 0,
    d: ?ffmpeg.Raw = null,
    last_hash: u64 = 0,
    grid: [frame_stats.grid_len]u8 = @splat(0),
    have_grid: bool = false,
};

fn decFor(decs: *[max_watch]Dec, n: *usize, api: *const ffmpeg.Api, ssrc: u32) ?*Dec {
    for (decs[0..n.*]) |*x| {
        if (x.ssrc == ssrc) return x;
    }
    if (n.* == decs.len) {
        // Sem vaga: reaproveita o mais antigo (a interface já não o vê).
        decs[0].ssrc = ssrc;
        if (decs[0].d) |*d| d.flush();
        decs[0].last_hash = 0;
        decs[0].have_grid = false;
        return &decs[0];
    }
    const x = &decs[n.*];
    x.* = .{ .ssrc = ssrc };
    x.d = ffmpeg.Raw.open(api, 4) catch null;
    if (x.d == null) return null;
    n.* += 1;
    return x;
}

fn decodeMain(_: ?*anyopaque) callconv(.c) c_int {
    const api = ffmpeg.get();
    var decs: [max_watch]Dec = @splat(.{});
    var n_decs: usize = 0;
    defer {
        for (decs[0..n_decs]) |*x| {
            if (x.d) |*d| d.close();
        }
    }
    if (api == null) status_now.store(@intFromEnum(Status.no_codec), .release);

    // A fila é do produtor: copia o quadro sob o mutex e decodifica depois.
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(alloc);
    while (true) {
        const m = lock orelse return 0;
        c.SDL_LockMutex(m);
        while (!stopping and q_len == 0 and !(pattern_on.load(.acquire) and n_watch != 0))
            _ = c.SDL_WaitConditionTimeout(cond.?, m, 100);
        if (stopping) {
            c.SDL_UnlockMutex(m);
            return 0;
        }
        if (q_len == 0) {
            c.SDL_UnlockMutex(m);
            patternFrame();
            c.SDL_Delay(16);
            continue;
        }
        const slot = queue[q_head];
        const len = slot.len;
        const ssrc = slot.ssrc;
        cur.resize(alloc, len) catch {
            q_head = (q_head + 1) % queue_n;
            q_len -= 1;
            c.SDL_UnlockMutex(m);
            continue;
        };
        @memcpy(cur.items[0..len], slot.buf[0..len]);
        // Tamanho do tile deste stream, decidido pela interface.
        var view: [2]u32 = .{ 0, 0 };
        for (watches[0..n_watch]) |wv| if (wv.ssrc == ssrc) {
            view = .{ wv.view_w, wv.view_h };
            break;
        };
        q_head = (q_head + 1) % queue_n;
        q_len -= 1;
        c.SDL_UnlockMutex(m);

        const a = api orelse continue;
        const dec = decFor(&decs, &n_decs, a, ssrc) orelse continue;
        const d = if (dec.d) |*x| x else continue;
        if (!d.send(cur.items[0..len])) {
            d.flush();
            setStatus(.stalled);
            continue;
        }
        while (d.receive() == 0) {
            const sz = d.size();
            if (sz[0] == 0 or sz[1] == 0) continue;
            src_w.store(sz[0], .release);
            src_h.store(sz[1], .release);
            const fit = fitSize(sz[0], sz[1], view[0], view[1]);
            publish(ssrc, d, fit, dec);
        }
    }
}

/// Copia o quadro decodificado para o buffer do stream, no tamanho do tile.
fn publish(ssrc: u32, d: *ffmpeg.Raw, fit: [2]u32, dec: *Dec) void {
    const m = lock orelse return;
    c.SDL_LockMutex(m);
    defer c.SDL_UnlockMutex(m);
    var tw: ?*Watch = null;
    for (watches[0..n_watch]) |*wv| {
        if (wv.ssrc == ssrc) {
            tw = wv;
            break;
        }
    }
    const wv = tw orelse return;
    if (wv.px.len < ffmpeg.rgbaSize(fit[0], fit[1])) {
        if (wv.px.len > 0) alloc.free(wv.px);
        wv.px = alloc.alloc(u8, ffmpeg.rgbaSize(max_w, max_h)) catch &.{};
    }
    if (wv.px.len == 0) return;
    if (!d.toRgba(wv.px[0..ffmpeg.rgbaSize(fit[0], fit[1])], fit[0], fit[1])) return;
    const px = wv.px[0..ffmpeg.rgbaSize(fit[0], fit[1])];
    var grid: [frame_stats.grid_len]u8 = undefined;
    frame_stats.sample(px, fit[0], fit[1], &grid);
    const h = frame_stats.hash(&grid);
    if (h != dec.last_hash) {
        _ = unique_now.fetchAdd(1, .monotonic);
        dec.last_hash = h;
    }
    if (dec.have_grid) {
        const md = frame_stats.diff(&grid, &dec.grid);
        const prev = motion_now.load(.monotonic);
        motion_now.store((prev * 7 + md) / 8, .release);
    }
    dec.grid = grid;
    dec.have_grid = true;
    wv.w = fit[0];
    wv.h = fit[1];
    wv.gen +%= 1;
    last_frame_ms.store(nowMs(), .release);
    _ = frames_now.fetchAdd(1, .monotonic);
    status_now.store(@intFromEnum(Status.playing), .release);
}

fn setStatus(s: Status) void {
    status_now.store(@intFromEnum(s), .release);
}

/// O "stream" da demonstração: um gradiente que anda, em 1280×720. Serve para
/// conferir a textura, a janela e o selo LIVE sem FFmpeg e sem Discord.
fn patternFrame() void {
    const m = lock orelse return;
    c.SDL_LockMutex(m);
    defer c.SDL_UnlockMutex(m);
    if (n_watch == 0) return;
    var i: usize = 0;
    while (i < n_watch) : (i += 1) {
        const wv = &watches[i];
        const fit = fitSize(1280, 720, wv.view_w, wv.view_h);
        const pw = fit[0];
        const ph = fit[1];
        src_w.store(1280, .release);
        src_h.store(720, .release);
        if (wv.px.len < ffmpeg.rgbaSize(max_w, max_h)) {
            if (wv.px.len > 0) alloc.free(wv.px);
            wv.px = alloc.alloc(u8, ffmpeg.rgbaSize(max_w, max_h)) catch &.{};
            if (wv.px.len == 0) return;
        }
        const t: u32 = @intCast(@mod(nowMs(), 6000));
        var y: u32 = 0;
        while (y < ph) : (y += 1) {
            const row = wv.px[y * pw * 4 ..][0 .. pw * 4];
            var x: u32 = 0;
            while (x < pw) : (x += 1) {
                const px = row[x * 4 ..][0..4];
                px[0] = @intCast((x * 200 / pw + t / 20 + i * 40) % 256);
                px[1] = @intCast((y * 160 / ph + t / 33) % 256);
                px[2] = @intCast((x + y + t / 7) % 256);
                px[3] = 255;
            }
        }
        wv.w = pw;
        wv.h = ph;
        wv.gen +%= 1;
    }
    last_frame_ms.store(nowMs(), .release);
    _ = frames_now.fetchAdd(1, .monotonic);
    _ = unique_now.fetchAdd(1, .monotonic);
    status_now.store(@intFromEnum(Status.playing), .release);
}

/// Reduz mantendo a proporção, dentro de max_w × max_h e do tamanho do tile.
fn fitSize(w: u32, h: u32, vw: u32, vh: u32) [2]u32 {
    var mw: u32 = max_w;
    var mh: u32 = max_h;
    if (vw > 0 and vh > 0) {
        mw = @min(mw, @max(vw, 2));
        mh = @min(mh, @max(vh, 2));
    }
    var rw: u32 = w;
    var rh: u32 = h;
    if (w > mw or h > mh) {
        if (@as(u64, w) * mh <= @as(u64, h) * mw) {
            rw = @max(1, @as(u32, @intCast(@as(u64, w) * mh / h)));
            rh = mh;
        } else {
            rw = mw;
            rh = @max(1, @as(u32, @intCast(@as(u64, h) * mw / w)));
        }
    }
    // Par: o swscale/SDL não gosta de linhas/colunas ímpares no fim.
    return .{ @max(2, rw & ~@as(u32, 1)), @max(2, rh & ~@as(u32, 1)) };
}
