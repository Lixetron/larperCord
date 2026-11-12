//! Voz de verdade: gateway de voz (v8), UDP, Opus, DAVE (E2EE) e SDL3.
//!
//! Tudo roda numa thread própria, criada só quando alguém entra numa call.
//! Fora de uma call este módulo não consome CPU: o app nem inicializa o áudio.
//!
//! O protocolo segue a documentação do Discord e do DAVE (https://daveprotocol.com):
//!   - WebSocket v8 com heartbeat (seq_ack) e RESUME quando a conexão cai;
//!   - IP discovery (pacote de 74 bytes) e Select Protocol;
//!   - RTP com aead_xchacha20_poly1305_rtpsize;
//!   - Opus 48 kHz estéreo, 20 ms por pacote, só enquanto alguém fala;
//!   - DAVE/MLS via libdave para as chamadas de hoje em dia.
//!
//! Áudio: o SDL3 mistura. Cada pessoa da call tem um SDL_AudioStream ligado
//! ao mesmo dispositivo de saída (o volume dela é o ganho do stream) e o
//! microfone é um stream lido a cada 20 ms. Nada de callback de áudio nem
//! buffer dividido entre threads. O que abrir e como (dispositivo pelo nome,
//! volumes, limiar, aperte para falar, filtros) vem de net/voz_audio.zig e de
//! core/voz.zig; o medidor e o teste de microfone das Configurações usam o
//! mesmo código numa thread à parte.
//!
//! `local` (a demonstração): só a metade do áudio, sem rede. O microfone, a
//! detecção de voz e o aviso de falha valem de verdade; nada sai do computador.
//!
//! LARPER_VOICE_DEBUG=1 mostra no terminal o que acontece na call (opcodes,
//! códigos de fechamento, DAVE). Nunca imprime token nem chaves.
const std = @import("std");
const sys = @import("../platform/sys.zig");
const c = @import("c");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const Sink = @import("fake_gateway.zig").Sink;
const i18n = @import("../ui/i18n.zig");
const j = @import("jsonx.zig");
const call_json = @import("call_json.zig");
const web = @import("web_client.zig");
const voz = @import("../core/voz.zig");
const voz_audio = @import("voz_audio.zig");
const voz_video = @import("voz_video.zig");
const video_rtp = @import("../core/video_rtp.zig");

const Id = types.Id;
const alloc = std.heap.c_allocator;
const nowMs = @import("fake_gateway.zig").nowMs;

const opus_rate = 48000;
const frame_ms = 20;
const frame_samples = opus_rate * frame_ms / 1000; // 960
const channels = 2;
const frame_bytes = frame_samples * channels * @sizeOf(i16); // 3840
const bytes_per_ms = opus_rate * channels * @sizeOf(i16) / 1000; // 192
const silence = [_]u8{ 0xF8, 0xFF, 0xFE };

/// Payload types que propomos no Select Protocol. O 96 é reservado para as
/// sondas do servidor; os nossos podem ser qualquer outro.
const opus_pt: u8 = 120;

/// Remontagem de um SSRC de vídeo assistido (a grade pode ter vários).
const DepSlot = struct { ssrc: u32 = 0, dep: video_rtp.Depacketizer = .{} };

fn queuedMs(st: *c.SDL_AudioStream) u32 {
    return @intCast(@divTrunc(@max(c.SDL_GetAudioStreamQueued(st), 0), bytes_per_ms));
}

var debug_on = false;
/// Chaves para o A/B do feedback (LARPER_VIDEO_NO_FB / _NO_CC / _NO_RR /
/// _NO_REMB): se o bitrate do remetente cair por causa do que mandamos, dá
/// para isolar qual relatório é o culpado.
var fb_cc = true;
var fb_rr = true;
var fb_remb = true;

fn debugOn() bool {
    return debug_on or @import("../platform/debug_log.zig").isOn();
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (debugOn()) std.log.info("voz: " ++ fmt, args);
}

/// Como a thread terminou (o gateway principal decide o que fazer).
pub const Ended = enum(u8) {
    running,
    /// Pedido nosso (saiu da call, trocou de canal).
    stopped,
    /// O Discord encerrou de vez (sessão inválida, recusou…). O gateway
    /// principal avisa o app, ou pede o canal de novo se acabamos de ser movidos.
    fatal,
    /// 4014/4022: o servidor de voz mudou ou alguém nos moveu. Espera um
    /// VOICE_SERVER_UPDATE novo para recomeçar.
    moved,
};

pub const Kind = enum { voice, stream };

pub const Voice = struct {
    sink: Sink,
    /// `stream` = espectador de um Go Live: outra conexão RTC, só recebe.
    kind: Kind = .voice,
    guild: Id = 0,
    /// O que vai no IDENTIFY (numa DM é o canal; num stream, o `rtc_server_id`).
    ident_server: Id = 0,
    ident_channel: Id = 0,
    /// Grupo do MLS do DAVE (o canal numa call; `media_session_id` num stream).
    dave_group: Id = 0,
    /// Muda quando alguém nos move de canal (o grupo do DAVE é o canal).
    channel: sys.Atomic(Id) = .init(0),
    user: Id = 0,
    endpoint: [256]u8 = @splat(0),
    endpoint_len: usize = 0,
    token: [256]u8 = @splat(0),
    token_len: usize = 0,
    session: [128]u8 = @splat(0),
    session_len: usize = 0,
    muted: std.atomic.Value(bool) = .init(false),
    deafened: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    ended: std.atomic.Value(Ended) = .init(.running),
    thread: ?*c.SDL_Thread = null,
    volume_mutex: ?*c.SDL_Mutex = null,
    volumes: std.AutoHashMapUnmanaged(Id, f32) = .empty,
    /// Sobe a cada mudança de volume (a thread de voz reaplica os ganhos).
    volumes_gen: std.atomic.Value(u32) = .init(0),
    /// Sem rede: só o microfone e a detecção de voz (a demonstração).
    local: bool = false,
    /// Segura uma referência do hub de vídeo (para o `stop` não soltar duas).
    video_ref: bool = false,

    pub fn init(sink: Sink, guild: Id, channel: Id, user: Id, endpoint: []const u8, token: []const u8, session: []const u8, mute: bool, deaf: bool) Voice {
        var v: Voice = .{
            .sink = sink,
            .guild = guild,
            .user = user,
            .ident_server = call_json.serverId(guild, channel),
            .ident_channel = channel,
            .dave_group = channel,
        };
        v.channel = .init(channel);
        v.endpoint_len = @min(endpoint.len, v.endpoint.len - 1);
        @memcpy(v.endpoint[0..v.endpoint_len], endpoint[0..v.endpoint_len]);
        v.token_len = @min(token.len, v.token.len - 1);
        @memcpy(v.token[0..v.token_len], token[0..v.token_len]);
        v.session_len = @min(session.len, v.session.len - 1);
        @memcpy(v.session[0..v.session_len], session[0..v.session_len]);
        v.muted = .init(mute);
        v.deafened = .init(deaf);
        v.volume_mutex = c.SDL_CreateMutex();
        return v;
    }

    /// Espectador de um Go Live: conexão própria, com o servidor/canal do
    /// Stream Create e o grupo DAVE = `media_session_id` (rtc_server_id - 1).
    pub fn initStream(sink: Sink, user: Id, server_id: Id, channel_id: Id, dave_group: Id, endpoint: []const u8, token: []const u8, session: []const u8) Voice {
        var v: Voice = .{
            .sink = sink,
            .kind = .stream,
            .user = user,
            .ident_server = server_id,
            .ident_channel = channel_id,
            .dave_group = dave_group,
        };
        v.channel = .init(channel_id);
        v.endpoint_len = @min(endpoint.len, v.endpoint.len - 1);
        @memcpy(v.endpoint[0..v.endpoint_len], endpoint[0..v.endpoint_len]);
        v.token_len = @min(token.len, v.token.len - 1);
        @memcpy(v.token[0..v.token_len], token[0..v.token_len]);
        v.session_len = @min(session.len, v.session.len - 1);
        @memcpy(v.session[0..v.session_len], session[0..v.session_len]);
        v.muted = .init(true);
        v.volume_mutex = c.SDL_CreateMutex();
        return v;
    }

    pub fn start(v: *Voice) !void {
        debug_on = c.SDL_getenv("LARPER_VOICE_DEBUG") != null;
        const all_off = c.SDL_getenv("LARPER_VIDEO_NO_FB") != null;
        fb_cc = !all_off and c.SDL_getenv("LARPER_VIDEO_NO_CC") == null;
        fb_rr = !all_off and c.SDL_getenv("LARPER_VIDEO_NO_RR") == null;
        fb_remb = !all_off and c.SDL_getenv("LARPER_VIDEO_NO_REMB") == null;
        voz_video.start();
        v.video_ref = true;
        v.thread = c.SDL_CreateThread(threadMain, "voice", v) orelse {
            voz_video.stop();
            v.video_ref = false;
            return error.SdlThread;
        };
    }

    pub fn stop(v: *Voice) void {
        v.stopping.store(true, .release);
        if (v.thread) |t| {
            c.SDL_WaitThread(t, null);
            v.thread = null;
        }
        // Só depois da thread de voz: ninguém mais empurra quadro.
        if (v.video_ref) {
            voz_video.stop();
            v.video_ref = false;
        }
    }

    pub fn deinit(v: *Voice) void {
        std.crypto.secureZero(u8, &v.token);
        std.crypto.secureZero(u8, &v.session);
        v.volumes.deinit(alloc);
        if (v.volume_mutex) |m| c.SDL_DestroyMutex(m);
    }

    pub fn setFlags(v: *Voice, mute: bool, deaf: bool) void {
        v.muted.store(mute, .release);
        v.deafened.store(deaf, .release);
    }

    pub fn setVolume(v: *Voice, user: Id, gain: f32) void {
        c.SDL_LockMutex(v.volume_mutex);
        defer c.SDL_UnlockMutex(v.volume_mutex);
        v.volumes.put(alloc, user, std.math.clamp(gain, 0, 2)) catch {};
        _ = v.volumes_gen.fetchAdd(1, .release);
    }

    /// Mudo por nós ou pelo servidor: nada de transmitir (nem abrir o microfone).
    fn micBlocked(v: *Voice) bool {
        return v.muted.load(.acquire) or v.deafened.load(.acquire) or
            voz_audio.sh.server_mute.load(.acquire) or voz_audio.sh.server_deaf.load(.acquire);
    }

    fn outBlocked(v: *Voice) bool {
        return v.deafened.load(.acquire) or voz_audio.sh.server_deaf.load(.acquire);
    }

    fn volumeOf(v: *Voice, user: Id) f32 {
        c.SDL_LockMutex(v.volume_mutex);
        defer c.SDL_UnlockMutex(v.volume_mutex);
        return v.volumes.get(user) orelse 1;
    }

    fn emit(v: *Voice, e: ev.Event) void {
        v.sink.push(v.sink.ctx, e);
    }

    fn status(v: *Voice, st: ev.VoiceStatus) void {
        // A conexão de stream não é a call: o painel de voz não muda com ela.
        if (v.kind == .stream) return;
        v.emit(.{ .voice_status = .{ .status = st, .channel = v.channel.load(.acquire) } });
    }

    fn notice(v: *Voice, comptime pt: []const u8, comptime en: []const u8, args: anytype) void {
        const s = i18n.allocPrint(alloc, pt, en, args) catch return;
        v.emit(.{ .notice = s });
    }

    fn threadMain(data: ?*anyopaque) callconv(.c) c_int {
        const v: *Voice = @ptrCast(@alignCast(data.?));
        // Compilar ou abrir imagens em paralelo não pode picotar a call.
        _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_HIGH);
        voz_audio.in_call.store(true, .release);
        defer voz_audio.in_call.store(false, .release);
        if (!v.local) v.status(.connecting);
        // `.fatal` não avisa o app daqui: quem decide é o gateway (net/discord.zig,
        // voiceLost). Só a demonstração, cujo gateway falso não confere `ended`.
        // O Worker tem buffers grandes: no heap, não na pilha da thread.
        const worker = alloc.create(Worker) catch {
            if (v.local) v.status(.disconnected);
            v.ended.store(.fatal, .release);
            return 0;
        };
        defer alloc.destroy(worker);
        worker.* = .{ .v = v };
        v.ended.store(if (v.local) worker.runLocal() else worker.run(), .release);
        return 0;
    }
};

// ---------------------------------------------------------------------------
// Estado da conexão (só existe na thread de voz)
// ---------------------------------------------------------------------------

/// Por que o laço da conexão parou.
const End = enum { stop, fatal, moved, resume_ws };

const Worker = struct {
    v: *Voice,
    ws: ?*c.CURL = null,
    ws_sock: sys.Socket = sys.no_socket,
    udp: sys.Socket = sys.no_socket,
    server: sys.SockAddrIn = undefined,
    ssrc: u32 = 0,
    secret: [32]u8 = @splat(0),
    have_secret: bool = false,
    rtp_seq: u16 = 0,
    rtp_ts: u32 = 0,
    nonce: u32 = 0,
    hb_interval: i64 = 13750,
    next_hb: i64 = std.math.maxInt(i64),
    hb_acked: bool = true,
    hb_sent_ms: i64 = 0,
    next_frame: i64 = 0,
    next_keepalive: i64 = 0,
    pull_ms: u32 = 22,
    last_seq: i64 = -1,
    connected: bool = false,
    resuming: bool = false,
    end: ?End = null,
    dave: ?Dave = null,
    /// Quem está na call e de quem é cada SSRC. Chegam (op 11, 5, 18, 20)
    /// antes da descrição da sessão, quando o DAVE ainda nem existe: ficam
    /// aqui e entram no DAVE quando ele nasce.
    call_users: std.AutoHashMapUnmanaged(Id, void) = .empty,
    call_ssrcs: std.AutoHashMapUnmanaged(u32, Id) = .empty,
    /// De quem é cada vídeo anunciado (op 12): usuário → SSRC do stream.
    video_users: std.AutoHashMapUnmanaged(Id, u32) = .empty,
    /// Remontagem do H.264 de cada SSRC assistido (grade da call).
    deps: [voz_video.max_watch]DepSlot = @splat(.{}),
    /// Buffer do DAVE em vídeo (o quadro inteiro, que o de áudio não comporta).
    video_plain: std.ArrayList(u8) = .empty,
    /// Os SSRCs que já pedimos ao servidor (op 15), na ordem enviada.
    subs: [voz_video.max_watch]u32 = @splat(0),
    n_sub: usize = 0,
    /// Último PLI (pedido de quadro-chave), para não repetir a cada tique.
    last_pli_ms: i64 = 0,
    /// Qualidade pedida ao SFU; cai sozinha se o vídeo não acompanhar.
    video_quality: u8 = 100,
    qcheck_ms: i64 = 0,
    qframes: u64 = 0,
    qshown: u64 = 0,
    /// Janelas seguidas ruins/boas e o começo da medição de qualidade (ms).
    qbad: u8 = 0,
    qgood: u8 = 0,
    qwarm_ms: i64 = 0,
    qb_bytes: u64 = 0,
    /// Sequência estendida do SSRC assistido, para o RTCP Receiver Report.
    v_last_seq: u16 = 0,
    v_cycle: u16 = 0,
    v_ext_seq: u32 = 0,
    v_have_seq: bool = false,
    rtcp_ms: i64 = 0,
    remb_ms: i64 = 0,
    /// Jitter RFC 3550 (1/90000 s) e o último Sender Report do SFU (RTT).
    v_jit: f64 = 0,
    v_jit_ts: u32 = 0,
    v_jit_arr_us: u64 = 0,
    v_jit_have: bool = false,
    sr_lsr: u32 = 0,
    sr_ms: i64 = 0,
    /// Pacotes de vídeo do SSRC assistido (para a taxa de perda no log).
    v_pkts: u64 = 0,
    v_stat_ms: i64 = 0,
    v_stat_frames: u64 = 0,
    v_stat_unique: u64 = 0,
    v_stat_bytes: u64 = 0,
    v_stat_pkts: u64 = 0,
    v_stat_seq: u32 = 0,
    /// Amostras de chegada do transport-cc, enviadas em lote a cada ~50 ms.
    cc_samples: [192]video_rtp.CcSample = undefined,
    cc_n: usize = 0,
    cc_media: u32 = 0,
    cc_next_ms: i64 = 0,
    cc_pkt: u8 = 0,
    /// Maior intervalo entre dois quadros completos na janela do log (ms).
    v_last_frame_ms: i64 = 0,
    v_gap_max: i64 = 0,
    /// Quantos intervalos caíram em <20, <40, <80 e 80+ ms.
    v_gap_hist: [4]u32 = .{ 0, 0, 0, 0 },
    /// Quadros-chave completos na janela do log.
    v_keys: u32 = 0,
    /// Último tamanho de fonte visto (para registrar quando o stream muda de
    /// resolução sem trocar de SSRC).
    v_src_w: u32 = 0,
    v_src_h: u32 = 0,
    /// SSRCs de vídeo que chegaram sem serem o assistido (camadas/simulcast).
    v_seen: [8]u32 = @splat(0),
    /// RTP ts do quadro anterior: o menor intervalo entre quadros dá o fps
    /// nominal do encoder; os intervalos grandes (saltos) mostram quadros que
    /// não chegaram até nós.
    v_last_ts: u32 = 0,
    v_have_ts: bool = false,
    v_ts_min: u32 = 0xffff_ffff,
    v_ts_big: u32 = 0,
    cc_missing: bool = false,
    encoder: ?*c.OpusEncoder = null,
    // Áudio.
    audio_on: bool = false,
    out: voz_audio.Output = .{},
    mic: voz_audio.Mic = .{},
    /// O que já avisamos à interface sobre o microfone e a saída.
    mic_ok_sent: bool = true,
    out_ok_sent: bool = true,
    deaf_applied: bool = false,
    volumes_gen: u32 = 0,
    sources: [32]Source = undefined,
    n_sources: usize = 0,
    // Detecção de fala (nossa).
    cap: voz.Capture = .{},
    talk: voz.Talk = .{},
    speaking_now: bool = false,
    speaking_emit_ms: i64 = 0,
    trailing_silence: u8 = 0,
    /// O próximo pacote é o primeiro de uma fala (bit de marcação do RTP).
    spurt_start: bool = true,
    // Diagnóstico (LARPER_VOICE_DEBUG).
    mic_peak_rms: f64 = 0,
    stats: Stats = .{},
    sent_frames: u64 = 0,
    stats_ms: i64 = 0,
    ws_in: std.ArrayList(u8) = .empty,
    in_buf: [65536]u8 = undefined,
    url_buf: [320]u8 = undefined,

    fn run(w: *Worker) Ended {
        defer w.cleanup();
        const url = w.buildUrl() orelse {
            w.v.notice("endereço de voz inválido", "invalid voice endpoint", .{});
            return .fatal;
        };
        if (!w.initAudio()) {
            // Sem placa/microfone ainda dá para ficar na call (o Discord
            // derruba quem não responde, não quem não fala).
            std.log.warn("voz: sem dispositivo de áudio", .{});
        }
        var tries: u8 = 0;
        while (!w.v.stopping.load(.acquire)) {
            if (!w.connectWs(url)) {
                tries += 1;
                if (tries > 3) {
                    w.v.notice("não consegui abrir a conexão de voz", "couldn't open the voice connection", .{});
                    return .fatal;
                }
                w.pause(@as(i64, tries) * 1000);
                continue;
            }
            w.end = null;
            w.next_hb = std.math.maxInt(i64);
            w.hb_acked = true;
            const opened_ms = nowMs();
            const how = w.loop();
            w.closeWs();
            // Ficou de pé um bom tempo: esta queda não é a mesma de antes.
            if (nowMs() - opened_ms >= 30_000) tries = 0;
            switch (how) {
                .stop => return .stopped,
                .fatal => return .fatal,
                .moved => return .moved,
                .resume_ws => {
                    tries += 1;
                    if (tries > 3) {
                        w.v.notice("a call caiu e não voltou", "the call dropped and didn't come back", .{});
                        return .fatal;
                    }
                    // Sem sessão completa ainda (sem chave): começa do zero.
                    w.resuming = w.have_secret;
                    dbg("reconectando (tentativa {d}, resume={})", .{ tries, w.resuming });
                    w.v.status(.connecting);
                    w.pause(@as(i64, tries) * 500);
                },
            }
        }
        return .stopped;
    }

    /// A demonstração: o áudio da call sem a call. Mesmo caminho até a hora de
    /// mandar o pacote (`sendRtp` não faz nada sem a chave).
    fn runLocal(w: *Worker) Ended {
        defer w.cleanup();
        _ = w.initAudio();
        w.next_frame = nowMs();
        while (!w.v.stopping.load(.acquire)) {
            const now = nowMs();
            w.applyAudioFlags();
            w.audioPoll(now);
            if (now >= w.next_frame) {
                w.sendFrame(now);
                w.next_frame += frame_ms;
                if (w.next_frame < now - 100) w.next_frame = now + frame_ms;
            }
            c.SDL_Delay(@intCast(std.math.clamp(w.next_frame - nowMs(), 1, frame_ms)));
        }
        return .stopped;
    }

    /// Espera sem travar o pedido de parar.
    fn pause(w: *Worker, ms: i64) void {
        const until = nowMs() + ms;
        while (nowMs() < until and !w.v.stopping.load(.acquire)) c.SDL_Delay(50);
    }

    fn buildUrl(w: *Worker) ?[:0]u8 {
        var ep: []const u8 = w.v.endpoint[0..w.v.endpoint_len];
        if (std.mem.startsWith(u8, ep, "wss://")) ep = ep[6..];
        if (std.mem.startsWith(u8, ep, "https://")) ep = ep[8..];
        if (ep.len == 0) return null;
        return std.fmt.bufPrintSentinel(&w.url_buf, "wss://{s}/?v=9", .{ep}, 0) catch null;
    }

    fn connectWs(w: *Worker, url: [:0]const u8) bool {
        const h = c.curl_easy_init() orelse return false;
        sys.curlTls(h);
        w.ws = h;
        _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(h, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECT_ONLY, @as(c_long, 2));
        _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 4000));
        _ = c.curl_easy_setopt(h, c.CURLOPT_HTTP_VERSION, @as(c_long, c.CURL_HTTP_VERSION_1_1));
        _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, web.user_agent.ptr);
        // O cliente web manda Origin também no handshake do gateway de voz.
        var hs_headers: ?*c.struct_curl_slist = null;
        hs_headers = c.curl_slist_append(hs_headers, "Origin: https://discord.com");
        defer if (hs_headers) |list| c.curl_slist_free_all(list);
        if (hs_headers) |list| _ = c.curl_easy_setopt(h, c.CURLOPT_HTTPHEADER, list);
        _ = c.curl_easy_setopt(h, c.CURLOPT_PROTOCOLS_STR, "https,wss");
        const rc = c.curl_easy_perform(h);
        if (rc != c.CURLE_OK) {
            std.log.warn("voz: curl {d}: {s}", .{ rc, c.curl_easy_strerror(rc) });
            w.closeWs();
            return false;
        }
        var sock: sys.Socket = sys.no_socket;
        _ = c.curl_easy_getinfo(h, c.CURLINFO_ACTIVESOCKET, &sock);
        if (!sys.valid(sock)) {
            w.closeWs();
            return false;
        }
        w.ws_sock = sock;
        dbg("websocket aberto", .{});
        return true;
    }

    fn closeWs(w: *Worker) void {
        if (w.ws) |h| c.curl_easy_cleanup(h);
        w.ws = null;
        w.ws_sock = sys.no_socket;
        w.ws_in.clearRetainingCapacity();
    }

    fn cleanup(w: *Worker) void {
        for (w.sources[0..w.n_sources]) |*s| s.deinit();
        w.n_sources = 0;
        w.cap.release();
        w.mic.close();
        w.out.close();
        if (w.audio_on) voz_audio.release();
        if (w.encoder) |e| c.opus_encoder_destroy(e);
        if (w.dave) |*d| d.deinit();
        if (sys.valid(w.udp)) sys.closeSocket(w.udp);
        w.closeWs();
        std.crypto.secureZero(u8, &w.secret);
        w.ws_in.deinit(alloc);
        w.call_users.deinit(alloc);
        w.call_ssrcs.deinit(alloc);
        w.video_users.deinit(alloc);
        for (&w.deps) |*slot| slot.dep.deinit(alloc);
        w.video_plain.deinit(alloc);
    }

    fn addCallUser(w: *Worker, uid: Id) void {
        w.call_users.put(alloc, uid, {}) catch {};
        if (w.dave) |*dave| dave.addUser(uid);
    }

    fn loop(w: *Worker) End {
        while (w.end == null) {
            if (w.v.stopping.load(.acquire)) return .stop;
            const now = nowMs();
            const next = if (w.connected) @min(w.next_hb, w.next_frame) else w.next_hb;
            const wait: c_int = @intCast(std.math.clamp(next - now, 0, 50));
            w.waitSockets(wait);
            const woke = nowMs();
            w.stats.wake_late_ms = @max(w.stats.wake_late_ms, woke - now - wait);
            w.readWs();
            w.readUdp();
            w.tick(nowMs());
            w.stats.busy_ms = @max(w.stats.busy_ms, nowMs() - woke);
        }
        return w.end.?;
    }

    fn waitSockets(w: *Worker, timeout_ms: c_int) void {
        var fds: [2]sys.PollFd = undefined;
        var n: usize = 0;
        if (sys.valid(w.ws_sock)) {
            fds[n] = .{ .fd = w.ws_sock, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        if (sys.valid(w.udp)) {
            fds[n] = .{ .fd = w.udp, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        if (n == 0) {
            c.SDL_Delay(@intCast(timeout_ms));
            return;
        }
        sys.poll(&fds, n, timeout_ms);
    }

    fn tick(w: *Worker, now: i64) void {
        if (now >= w.next_hb) {
            // Dois heartbeats sem resposta: a conexão morreu sem avisar.
            if (!w.hb_acked) {
                dbg("heartbeat sem resposta", .{});
                w.end = .resume_ws;
                return;
            }
            w.heartbeat();
            w.next_hb = now + w.hb_interval;
        }
        w.applyAudioFlags();
        w.audioPoll(now);
        if (!w.connected) return;
        // A interface pode ter escolhido outro stream: o servidor precisa saber.
        w.syncWatch(false);
        // Perdemos um quadro e o decodificador está parado: pede outro
        // quadro-chave de vez em quando (o SFU também manda por conta dele).
        if (w.n_sub > 0 and (voz_video.status() == .stalled or w.deps[0].dep.need_key) and now - w.last_pli_ms >= 1000) {
            w.sendPli(w.primary());
            w.last_pli_ms = now;
        }
        // Vídeo pesado demais (1440p num CPU fraco): pede uma qualidade menor
        // ao SFU, que ajusta resolução/bitrate do encoder. Duas janelas ruins
        // seguidas para descer — o começo do stream (flush, keyframe) não conta
        // — e volta a subir quando o decodificador se recupera.
        if (w.n_sub == 0) {
            w.qcheck_ms = 0;
            w.qbad = 0;
            w.qgood = 0;
        } else {
            const st = voz_video.stats();
            if (w.qcheck_ms == 0) {
                w.qcheck_ms = now;
                w.qwarm_ms = now;
                w.qframes = st.frames;
                w.qshown = st.shown;
                w.qb_bytes = st.bytes;
                w.qbad = 0;
                w.qgood = 0;
            } else if (now - w.qcheck_ms >= 2000) {
                const dt: u64 = @intCast(@max(now - w.qcheck_ms, 1));
                const dec = (st.frames - w.qframes) * 1000 / dt;
                const shown = (st.shown - w.qshown) * 1000 / dt;
                const mbps_in = @as(f64, @floatFromInt(st.bytes - w.qb_bytes)) * 8 / @as(f64, @floatFromInt(dt)) / 1000;
                w.qcheck_ms = now;
                w.qframes = st.frames;
                w.qshown = st.shown;
                w.qb_bytes = st.bytes;
                const src = voz_video.sourceSize();
                // Nos primeiros segundos o decodificador enche o buffer e o SFU
                // sobe o bitrate: medir aí só produzia queda sem motivo. E só
                // desce se o bitrate que chega for alto: com o SFU já mandando
                // pouco, baixar a qualidade só piora.
                const warm = now - w.qwarm_ms < 5000;
                const heavy = !warm and dec > 0 and dec < 26 and (src[0] > 1280 or src[1] > 720) and mbps_in > 3.0;
                const stall = !warm and shown > 0 and shown < 26 and dec >= 40;
                if (heavy or stall) {
                    w.qgood = 0;
                    w.qbad +|= 1;
                    if (w.qbad >= 2 and w.video_quality > 40) {
                        w.video_quality -= 20;
                        w.sendSinkWants();
                        dbg("vídeo a {d} dec/{d} exib ({d:.1} Mbps): pedindo qualidade {d}", .{ dec, shown, mbps_in, w.video_quality });
                        w.qbad = 0;
                    }
                } else {
                    w.qbad = 0;
                    if (dec >= 50 and w.video_quality < 100) {
                        w.qgood +|= 1;
                        if (w.qgood >= 3) {
                            w.video_quality = @min(100, w.video_quality + 20);
                            w.sendSinkWants();
                            dbg("vídeo a {d} dec/{d} exib: voltando à qualidade {d}", .{ dec, shown, w.video_quality });
                            w.qgood = 0;
                        }
                    } else {
                        w.qgood = 0;
                    }
                }
            }
        }
        // Transport-cc em lote (um RTCP a cada 50 ms, como o Chrome).
        if (w.n_sub > 0 and fb_cc and now >= w.cc_next_ms) {
            w.flushTransportCc(now);
            w.cc_next_ms = now + 50;
        }
        // Frequência de recepção (1 Hz) para o SFU estimar o canal.
        if (w.n_sub > 0 and w.v_have_seq and now - w.rtcp_ms >= 1000) {
            w.sendRtcpRr(w.primary());
            w.rtcp_ms = now;
        }
        // REMB (2 Hz de sobra): 6 Mbps de teto para o encoder não se apertar.
        if (w.n_sub > 0 and now - w.remb_ms >= 2000) {
            w.sendRemb(w.primary(), 6_000_000);
            w.remb_ms = now;
        }
        // Diagnóstico do que chega: fps, quadros novos, bitrate e perda. É o
        // que distingue "o encoder manda pouco" de "perdemos pacotes".
        if (debugOn() and w.n_sub > 0) {
            const st = voz_video.stats();
            // O remetente pode reencodar noutra resolução sem trocar de SSRC.
            const src = voz_video.sourceSize();
            if (src[0] != 0 and (src[0] != w.v_src_w or src[1] != w.v_src_h)) {
                w.v_src_w = src[0];
                w.v_src_h = src[1];
                dbg("fonte do vídeo: {d}x{d}", .{ src[0], src[1] });
            }
            if (w.v_stat_ms == 0) {
                w.v_stat_ms = now;
                w.v_stat_frames = st.frames;
                w.v_stat_unique = st.unique;
                w.v_stat_bytes = st.bytes;
                w.v_stat_pkts = w.v_pkts;
                w.v_stat_seq = w.v_ext_seq;
            } else if (now - w.v_stat_ms >= 5000) {
                const dt: u64 = @intCast(@max(now - w.v_stat_ms, 1));
                const fps = (st.frames - w.v_stat_frames) * 1000 / dt;
                const uniq = (st.unique - w.v_stat_unique) * 1000 / dt;
                const mbps = @as(f64, @floatFromInt(st.bytes - w.v_stat_bytes)) * 8 / @as(f64, @floatFromInt(dt)) / 1000;
                const expected = w.v_ext_seq -% w.v_stat_seq;
                const got = w.v_pkts - w.v_stat_pkts;
                const loss = if (expected > 0 and got <= expected)
                    @as(f64, @floatFromInt(expected - got)) * 100 / @as(f64, @floatFromInt(expected))
                else
                    0;
                const dframes = st.frames - w.v_stat_frames;
                const avg_frame = if (dframes > 0) (st.bytes - w.v_stat_bytes) / dframes else 0;
                const pps = (w.v_pkts - w.v_stat_pkts) * 1000 / dt;
                const enc_fps: u64 = if (w.v_ts_min != 0xffff_ffff and w.v_ts_min > 0) 90000 / w.v_ts_min else 0;
                dbg("vídeo: {d} dec/s, {d} novos/s, mov {d}, {d:.2} Mbps, perda {d:.1}%, q={d}, src {d}x{d}, enc {d} fps, saltos {d}, fb={s}/{s}/{s}, key {d}, gaps {d}/{d}/{d}/{d}, quadro {d} B, {d} pkt/s", .{
                    fps, uniq, st.motion, mbps, loss, w.video_quality, src[0], src[1], enc_fps, w.v_ts_big,
                    if (fb_cc) "on" else "off",
                    if (fb_rr) "on" else "off",
                    if (fb_remb) "on" else "off",
                    w.v_keys,
                    w.v_gap_hist[0], w.v_gap_hist[1], w.v_gap_hist[2], w.v_gap_hist[3],
                    avg_frame, pps,
                });
                w.v_gap_max = 0;
                w.v_gap_hist = .{ 0, 0, 0, 0 };
                w.v_keys = 0;
                w.v_ts_min = 0xffff_ffff;
                w.v_ts_big = 0;
                w.v_stat_ms = now;
                w.v_stat_frames = st.frames;
                w.v_stat_unique = st.unique;
                w.v_stat_bytes = st.bytes;
                w.v_stat_pkts = w.v_pkts;
                w.v_stat_seq = w.v_ext_seq;
            }
        }
        if (now >= w.next_keepalive) {
            const keep = [_]u8{ 0x13, 0x37 };
            _ = sys.sendTo(w.udp, &keep, &w.server);
            w.next_keepalive = now + 5000;
        }
        if (w.v.kind == .voice and now >= w.next_frame) {
            w.sendFrame(now);
            w.next_frame += frame_ms;
            // O relógio do RTP anda com o tempo, falando ou não: quem recebe
            // usa ele para saber quanto tempo passou entre duas falas.
            w.rtp_ts +%= frame_samples;
            if (w.next_frame < now - 100) w.next_frame = now + frame_ms; // não acumula atraso
            if (debugOn()) w.watchQueues();
        }
        w.conceal();
        w.expireSpeakers(now);
    }

    // --- WebSocket ---------------------------------------------------------

    fn sendFrame_(w: *Worker, flags0: c_uint, data: []const u8) bool {
        const h = w.ws orelse return false;
        var off: usize = 0;
        var first = true;
        var waited: u8 = 0;
        while (off < data.len) {
            var sent: usize = 0;
            const flags: c_uint = if (first) flags0 else c.CURLWS_CONT;
            const rc = c.curl_ws_send(h, data.ptr + off, data.len - off, &sent, 0, flags);
            if (rc == c.CURLE_AGAIN) {
                waited += 1;
                if (waited > 50) return false;
                w.waitSockets(20);
                continue;
            }
            if (rc != c.CURLE_OK) {
                dbg("ws send rc={d}", .{rc});
                // Socket morto: o laço reconecta em vez de insistir.
                if (w.end == null) w.end = .resume_ws;
                return false;
            }
            if (sent == 0) return false;
            off += sent;
            first = false;
        }
        return true;
    }

    fn sendText(w: *Worker, text: []const u8) bool {
        return w.sendFrame_(c.CURLWS_TEXT, text);
    }

    fn sendBinary(w: *Worker, opcode: u8, payload: []const u8) bool {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        buf.ensureTotalCapacity(alloc, payload.len + 1) catch return false;
        buf.appendAssumeCapacity(opcode);
        buf.appendSliceAssumeCapacity(payload);
        dbg("enviou binário op {d} ({d} bytes)", .{ opcode, payload.len });
        return w.sendFrame_(c.CURLWS_BINARY, buf.items);
    }

    fn heartbeat(w: *Worker) void {
        var b: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":3,\"d\":{{\"t\":{d},\"seq_ack\":{d}}}}}", .{ nowMs(), w.last_seq }) catch return;
        w.hb_acked = false;
        w.hb_sent_ms = nowMs();
        _ = w.sendText(p);
    }

    fn identify(w: *Worker) void {
        var out: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, out.items);
            out.deinit(alloc);
        }
        // Numa DM ou grupo o `server_id` é o canal (call_json.serverId).
        call_json.writeIdentify(&out, alloc, w.v.ident_server, w.v.ident_channel, w.v.user, w.v.session[0..w.v.session_len], w.v.token[0..w.v.token_len], @intCast(c.daveMaxSupportedProtocolVersion())) catch return;
        dbg("identify (DAVE até v{d})", .{c.daveMaxSupportedProtocolVersion()});
        _ = w.sendText(out.items);
    }

    /// Op 7: retoma a mesma sessão depois de uma queda (o UDP continua).
    fn sendResume(w: *Worker) void {
        var out: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, out.items);
            out.deinit(alloc);
        }
        call_json.writeResume(&out, alloc, w.v.ident_server, w.v.ident_channel, w.v.session[0..w.v.session_len], w.v.token[0..w.v.token_len], w.last_seq) catch return;
        dbg("resume", .{});
        _ = w.sendText(out.items);
    }

    fn readWs(w: *Worker) void {
        const h = w.ws orelse return;
        while (w.end == null) {
            var got: usize = 0;
            var meta: [*c]const c.struct_curl_ws_frame = null;
            const rc = c.curl_ws_recv(h, &w.in_buf, w.in_buf.len, &got, &meta);
            if (rc == c.CURLE_AGAIN) return;
            if (rc != c.CURLE_OK or meta == null) {
                // Conexão caiu sem o Discord fechar (rede, NAT, suspensão).
                dbg("ws recv rc={d}", .{rc});
                w.end = .resume_ws;
                return;
            }
            const flags = meta.*.flags;
            if (flags & c.CURLWS_CLOSE != 0) {
                const code: u16 = if (got >= 2) (@as(u16, w.in_buf[0]) << 8) | w.in_buf[1] else 0;
                const reason = if (got > 2) w.in_buf[2..got] else "";
                std.log.warn("voz: fechou {d}: {s}", .{ code, reason });
                w.end = w.onClose(code);
                return;
            }
            if (flags & (c.CURLWS_PING | c.CURLWS_PONG) != 0) continue;
            if (got > 0) w.ws_in.appendSlice(alloc, w.in_buf[0..got]) catch return;
            // Mensagem em vários pedaços: junta até o último.
            if (meta.*.bytesleft != 0 or flags & c.CURLWS_CONT != 0) continue;
            const bytes = w.ws_in.items;
            if (bytes.len > 0) {
                if (flags & c.CURLWS_TEXT != 0) {
                    w.onText(bytes);
                } else if (flags & c.CURLWS_BINARY != 0) {
                    w.onBinary(bytes);
                }
            }
            w.ws_in.clearRetainingCapacity();
        }
    }

    /// O que fazer com cada código de fechamento do gateway de voz.
    fn onClose(w: *Worker, code: u16) End {
        w.connected = false;
        if (w.v.stopping.load(.acquire)) return .stop;
        return switch (code) {
            // Queda de rede / servidor reiniciou: retoma a mesma sessão.
            0, 1000, 1001, 1006, 4015 => .resume_ws,
            // Movido de canal, servidor de voz trocado ou desconectado por
            // alguém (4022: a call inteira acabou ali, servidor trocado ou canal
            // apagado): o gateway principal manda (ou não) o servidor novo.
            4014, 4022 => .moved,
            4004 => blk: {
                w.v.notice("o Discord recusou a sessão de voz (4004).", "Discord refused the voice session (4004).", .{});
                break :blk .fatal;
            },
            4006, 4009 => blk: {
                w.v.notice("a sessão de voz não vale mais; entre na call de novo.", "the voice session is no longer valid; join the call again.", .{});
                break :blk .fatal;
            },
            4016, 4017 => blk: {
                w.v.notice("o Discord exigiu E2EE (DAVE) e a negociação falhou ({d}).", "Discord requires E2EE (DAVE) and negotiation failed ({d}).", .{code});
                break :blk .fatal;
            },
            else => blk: {
                w.v.notice("a call caiu (código {d}).", "the call dropped (code {d}).", .{code});
                break :blk .fatal;
            },
        };
    }

    fn onText(w: *Worker, text: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch return;
        if (j.int(j.get(root, "seq"))) |s| w.last_seq = s;
        const op = j.int(j.get(root, "op")) orelse return;
        const d = j.get(root, "d") orelse std.json.Value{ .null = {} };
        if (op != 6) dbg("op {d}", .{op});
        switch (op) {
            8 => {
                w.hb_interval = @max(j.int(j.get(d, "heartbeat_interval")) orelse 13750, 1000);
                // O primeiro heartbeat vai logo (com jitter), como o cliente oficial.
                w.next_hb = nowMs() + @divTrunc(w.hb_interval, 4);
                if (w.resuming) w.sendResume() else w.identify();
            },
            6 => {
                w.hb_acked = true;
                if (w.hb_sent_ms != 0 and w.v.kind == .voice) w.v.emit(.{ .voice_ping = @intCast(std.math.clamp(nowMs() - w.hb_sent_ms, 1, 60_000)) });
            },
            2 => w.onReady(d),
            4 => w.onSession(d),
            9 => {
                // Resumed: o UDP e a chave continuam valendo.
                w.resuming = false;
                w.connected = w.have_secret;
                w.next_frame = nowMs();
                if (w.connected) {
                    w.announceSpeaking();
                    w.announceVideo();
                    // A sessão retomada também perdeu os pedidos de vídeo.
                    w.n_sub = 0;
                    for (&w.deps) |*slot| { slot.ssrc = 0; slot.dep.reset(); }
                    w.syncWatch(true);
                    w.v.status(.connected);
                }
            },
            5 => w.onSpeaking(d),
            11 => for (j.array(j.get(d, "user_ids"))) |u| {
                if (j.id(u)) |uid| w.addCallUser(uid);
            },
            // Flags e plataforma de quem está na call: também diz que ele está aqui.
            18, 20 => if (j.id(j.get(d, "user_id"))) |uid| w.addCallUser(uid),
            12 => w.onVideo(d),
            13 => if (j.id(j.get(d, "user_id"))) |uid| {
                _ = w.call_users.remove(uid);
                _ = w.video_users.remove(uid);
                w.removeSource(uid);
                voz_video.removeUser(uid);
                if (w.dave) |*dave| dave.removeUser(uid);
                w.v.emit(.{ .voice_speaking = .{ .user = uid, .speaking = false } });
                w.v.emit(.{ .voice_video = .{ .user = uid, .video_ssrc = 0, .active = false } });
                if (voz_video.watching() == uid) w.syncWatch(true);
            },
            21 => {
                const ver: u16 = @intCast(std.math.clamp(j.int(j.get(d, "protocol_version")) orelse 1, 0, 1));
                const tid = j.int(j.get(d, "transition_id")) orelse 0;
                if (w.dave) |*dave| {
                    dave.prepareTransition(ver);
                    // 0 = (re)início: executa já, sem esperar o servidor.
                    if (tid == 0) dave.executeTransition() else w.sendReady(tid);
                } else if (tid != 0) w.sendReady(tid);
            },
            22 => if (w.dave) |*dave| dave.executeTransition(),
            24 => {
                const epoch = j.int(j.get(d, "epoch")) orelse 0;
                const ver: u16 = @intCast(std.math.clamp(j.int(j.get(d, "protocol_version")) orelse 1, 0, 1));
                if (epoch == 1 and ver > 0) {
                    // Grupo novo: esquece o estado local e manda outro key package.
                    if (w.dave == null) w.initDave(ver);
                    if (w.dave) |*dave| {
                        dave.reinit(ver, w.v.dave_group);
                        w.sendKeyPackage();
                    }
                }
            },
            else => {},
        }
    }

    fn sendReady(w: *Worker, tid: i64) void {
        var b: [80]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":23,\"d\":{{\"transition_id\":{d}}}}}", .{tid}) catch return;
        _ = w.sendText(p);
    }

    fn onBinary(w: *Worker, data: []const u8) void {
        // Do servidor: seq (u16, big endian) + opcode + dados.
        if (data.len < 3) return;
        w.last_seq = std.mem.readInt(u16, data[0..2], .big);
        const opcode = data[2];
        const payload = data[3..];
        dbg("binário op {d} ({d} bytes)", .{ opcode, payload.len });
        const dave = if (w.dave) |*d| d else return;
        switch (opcode) {
            25 => dave.setExternalSender(payload),
            27 => {
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(alloc);
                dave.proposals(payload, &out);
                if (out.items.len > 0) _ = w.sendBinary(28, out.items);
            },
            29, 30 => {
                if (payload.len < 2) return;
                const tid = std.mem.readInt(u16, payload[0..2], .big);
                const ok = if (opcode == 29) dave.commit(tid, payload[2..]) else dave.welcome(tid, payload[2..]);
                const res = ok orelse return; // commit ignorado (nosso mesmo)
                if (res) {
                    if (tid != 0) w.sendReady(tid);
                    dave.setLocalSsrc(w.ssrc);
                } else {
                    // Commit/welcome inválido: avisa (op 31), recomeça o MLS
                    // e manda um key package novo.
                    dbg("commit/welcome inválido (transição {d})", .{tid});
                    w.sendInvalid(tid);
                    dave.reinit(dave.version, w.v.dave_group);
                    w.sendKeyPackage();
                }
            },
            else => {},
        }
    }

    fn sendInvalid(w: *Worker, tid: i64) void {
        var b: [80]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":31,\"d\":{{\"transition_id\":{d}}}}}", .{tid}) catch return;
        _ = w.sendText(p);
    }

    fn parseIp4(ip: []const u8, port: u16) !sys.SockAddrIn {
        var z: [64]u8 = @splat(0);
        if (ip.len == 0 or ip.len >= z.len) return error.InvalidAddress;
        @memcpy(z[0..ip.len], ip);
        return sys.ipv4(@ptrCast(&z), port) orelse error.InvalidAddress;
    }

    fn onReady(w: *Worker, d: std.json.Value) void {
        const ip = j.str(j.get(d, "ip")) orelse return;
        const port: u16 = @intCast(std.math.clamp(j.int(j.get(d, "port")) orelse 0, 0, 65535));
        w.ssrc = @intCast(std.math.clamp(j.int(j.get(d, "ssrc")) orelse 0, 0, std.math.maxInt(u32)));
        if (port == 0) return;
        w.server = parseIp4(ip, port) catch {
            w.v.notice("endereço UDP de voz inválido", "invalid voice UDP address", .{});
            w.end = .fatal;
            return;
        };
        if (sys.valid(w.udp)) sys.closeSocket(w.udp);
        const fd = sys.udpSocket() orelse {
            w.v.notice("não consegui abrir o UDP da call", "couldn't open the call UDP", .{});
            w.end = .fatal;
            return;
        };
        w.udp = fd;
        if (!sys.bindAny(w.udp)) {
            w.v.notice("não consegui abrir o UDP da call", "couldn't open the call UDP", .{});
            w.end = .fatal;
            return;
        }
        // IP discovery: o pedido tem 74 bytes (cabeçalho de 4 + ssrc + 66).
        var pkt: [74]u8 = @splat(0);
        std.mem.writeInt(u16, pkt[0..2], 1, .big);
        std.mem.writeInt(u16, pkt[2..4], 70, .big);
        std.mem.writeInt(u32, pkt[4..8], w.ssrc, .big);
        for (0..5) |_| {
            _ = sys.sendTo(w.udp, &pkt, &w.server);
            const deadline = nowMs() + 1000;
            while (nowMs() < deadline and !w.v.stopping.load(.acquire)) {
                w.waitSockets(100);
                var resp: [256]u8 = undefined;
                const nr = sys.recvNow(w.udp, &resp);
                if (nr < 74) continue;
                if (std.mem.readInt(u16, resp[0..2], .big) != 2) continue;
                const iplen = std.mem.indexOfScalar(u8, resp[8..72], 0) orelse 64;
                const ext_port = std.mem.readInt(u16, resp[72..74], .big);
                dbg("discovery ok (porta {d})", .{ext_port});
                w.selectProtocol(resp[8..][0..iplen], ext_port);
                return;
            }
        }
        w.v.notice("a call não respondeu ao UDP (firewall/NAT?)", "the call didn't answer on UDP (firewall/NAT?)", .{});
        w.end = .fatal;
    }

    fn selectProtocol(w: *Worker, ip: []const u8, port: u16) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        call_json.writeSelectProtocol(&out, alloc, ip, port) catch return;
        _ = w.sendText(out.items);
    }

    fn onSession(w: *Worker, d: std.json.Value) void {
        const mode = j.str(j.get(d, "mode")) orelse "";
        if (!std.mem.eql(u8, mode, "aead_xchacha20_poly1305_rtpsize")) {
            w.v.notice("modo de criptografia de voz não suportado ({s})", "unsupported voice encryption mode ({s})", .{mode});
            w.end = .fatal;
            return;
        }
        const keys = j.array(j.get(d, "secret_key"));
        if (keys.len != 32) return;
        for (keys, 0..) |kv, i| w.secret[i] = @intCast(std.math.clamp(j.int(kv) orelse 0, 0, 255));
        w.have_secret = true;
        const dave_ver: u16 = @intCast(std.math.clamp(j.int(j.get(d, "dave_protocol_version")) orelse 0, 0, 1));
        const vcodec = j.str(j.get(d, "video_codec")) orelse "";
        // `video_codec` é o que *enviamos*; não enviamos vídeo. Quem manda
        // para nós escolhe entre o que dissemos decodificar (só H.264).
        if (vcodec.len > 0 and !std.mem.eql(u8, vcodec, "H264")) dbg("sessão pede {s} para enviar; só recebemos H.264", .{vcodec});
        dbg("sessão pronta (DAVE v{d})", .{dave_ver});
        if (dave_ver > 0 and w.dave == null) {
            w.initDave(dave_ver);
            w.sendKeyPackage();
        }
        w.announceSpeaking();
        w.connected = true;
        w.next_frame = nowMs();
        w.next_keepalive = nowMs();
        // O servidor esqueceu o que pedimos: pede de novo o stream assistido.
        w.n_sub = 0;
        for (&w.deps) |*slot| { slot.ssrc = 0; slot.dep.reset(); }
        w.video_users.clearRetainingCapacity();
        voz_video.clearStreams();
        w.syncWatch(true);
        // O servidor espera um op 12 antes de mandar vídeo; com 0/[] dizemos
        // que só assistimos (o `video:true` do identify é a capacidade).
        w.announceVideo();
        w.v.status(.connected);
    }

    /// Op 12: "não transmito vídeo" (mas recebo). Também reinicia o estado de
    /// vídeo depois de um RESUME.
    fn announceVideo(w: *Worker) void {
        var b: [128]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":12,\"d\":{{\"audio_ssrc\":{d},\"video_ssrc\":0,\"rtx_ssrc\":0,\"streams\":[]}}}}", .{w.ssrc}) catch return;
        _ = w.sendText(p);
    }

    fn onSpeaking(w: *Worker, d: std.json.Value) void {
        const uid = j.id(j.get(d, "user_id")) orelse return;
        const ssrc: u32 = @intCast(std.math.clamp(j.int(j.get(d, "ssrc")) orelse 0, 0, std.math.maxInt(u32)));
        if (ssrc == 0) return;
        _ = w.sourceFor(ssrc, uid);
        w.addCallUser(uid);
        w.call_ssrcs.put(alloc, ssrc, uid) catch {};
        if (w.dave) |*dave| dave.setSsrcUser(ssrc, uid);
    }

    /// Uma linha com os campos de um objeto JSON, para o log de diagnóstico.
    fn dumpObject(o: std.json.ObjectMap, a: std.mem.Allocator, buf: *std.ArrayList(u8)) void {
        dumpObjectDepth(o, a, buf, 1);
    }

    fn dumpObjectDepth(o: std.json.ObjectMap, a: std.mem.Allocator, buf: *std.ArrayList(u8), depth: u8) void {
        var it = o.iterator();
        while (it.next()) |kv| {
            switch (kv.value_ptr.*) {
                .integer => |n| buf.print(a, "{s}={d} ", .{ kv.key_ptr.*, n }) catch return,
                .float => |f| buf.print(a, "{s}={d:.2} ", .{ kv.key_ptr.*, f }) catch return,
                .string => |s| buf.print(a, "{s}=\"{s}\" ", .{ kv.key_ptr.*, s }) catch return,
                .bool => |b| buf.print(a, "{s}={} ", .{ kv.key_ptr.*, b }) catch return,
                .array => |arr| buf.print(a, "{s}=[{d}] ", .{ kv.key_ptr.*, arr.items.len }) catch return,
                .object => |sub| {
                    buf.print(a, "{s}={{", .{kv.key_ptr.*}) catch return;
                    if (depth > 0) dumpObjectDepth(sub, a, buf, depth - 1);
                    buf.appendSlice(a, "} ") catch return;
                },
                .number_string => |s| buf.print(a, "{s}=%{s} ", .{ kv.key_ptr.*, s }) catch return,
                else => {},
            }
        }
    }

    /// Op 12: quem está transmitindo vídeo e com qual SSRC. O servidor manda um
    /// por pessoa ao conectar e a cada mudança (câmera/stream ligado ou não).
    fn onVideo(w: *Worker, d: std.json.Value) void {
        const uid = j.id(j.get(d, "user_id")) orelse return;
        if (uid == w.v.user) return;
        if (debugOn()) {
            var b: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&b);
            const a = fba.allocator();
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(a);
            switch (d) {
                .object => |o| dumpObject(o, a, &buf),
                else => {},
            }
            for (j.array(j.get(d, "streams"))) |s| switch (s) {
                .object => |o| {
                    buf.appendSlice(a, "| ") catch break;
                    dumpObject(o, a, &buf);
                },
                else => {},
            };
            dbg("op 12: {s}", .{buf.items});
        }
        var ssrc: u32 = @intCast(std.math.clamp(j.int(j.get(d, "video_ssrc")) orelse 0, 0, std.math.maxInt(u32)));
        var rtx: u32 = @intCast(std.math.clamp(j.int(j.get(d, "rtx_ssrc")) orelse 0, 0, std.math.maxInt(u32)));
        var best_q: i64 = -1;
        var best_ssrc: u32 = 0;
        var best_rtx: u32 = 0;
        const list = j.array(j.get(d, "streams"));
        for (list) |s| {
            const ss: u32 = @intCast(std.math.clamp(j.int(j.get(s, "ssrc")) orelse 0, 0, std.math.maxInt(u32)));
            if (ss == 0) continue;
            const q = j.int(j.get(s, "quality")) orelse 0;
            if (q <= best_q) continue;
            best_q = q;
            best_ssrc = ss;
            best_rtx = @intCast(std.math.clamp(j.int(j.get(s, "rtx_ssrc")) orelse 0, 0, std.math.maxInt(u32)));
        }
        if (best_ssrc != 0) {
            // O layer de maior qualidade pode estar inativo até alguém pedir
            // (simulcast): pedimos ele mesmo assim, com op 15 qualidade 100.
            ssrc = best_ssrc;
            rtx = best_rtx;
        }
        if (debugOn()) {
            for (list) |s| {
                const ss: u32 = @intCast(std.math.clamp(j.int(j.get(s, "ssrc")) orelse 0, 0, std.math.maxInt(u32)));
                if (ss == 0) continue;
                const rid = j.str(j.get(s, "rid")) orelse "";
                const q = j.int(j.get(s, "quality")) orelse 0;
                const act = if (j.get(s, "active")) |a| a == .bool and a.bool else false;
                var rw: i64 = 0;
                var rh: i64 = 0;
                if (j.get(s, "max_resolution")) |r| {
                    rw = j.int(j.get(r, "width")) orelse 0;
                    rh = j.int(j.get(r, "height")) orelse 0;
                }
                const mb = j.int(j.get(s, "max_bitrate")) orelse 0;
                const mf = j.int(j.get(s, "max_framerate")) orelse 0;
                dbg("camada {d}: rid={s} q={d} ativo={} {d}x{d} bitrate={d} fps={d}", .{ ss, rid, q, act, rw, rh, mb, mf });
            }
        }
        if (ssrc == 0) {
            _ = w.video_users.remove(uid);
            voz_video.setStream(uid, 0, 0, false);
            if (w.v.kind == .voice) w.v.emit(.{ .voice_video = .{ .user = uid, .video_ssrc = 0, .active = false } });
            if (voz_video.watching() == uid) w.syncWatch(true);
            return;
        }
        w.video_users.put(alloc, uid, ssrc) catch {};
        w.addCallUser(uid);
        // O DAVE do vídeo usa o SSRC do vídeo; a chave é a mesma pessoa.
        if (w.dave) |*dave| dave.setSsrcUser(ssrc, uid);
        voz_video.setStream(uid, ssrc, rtx, true);
        // A interface só marca LIVE de câmera pelo op 12 da voz; o Go Live já
        // aparece pelo `self_stream` do VOICE_STATE_UPDATE.
        if (w.v.kind == .voice) w.v.emit(.{ .voice_video = .{ .user = uid, .video_ssrc = ssrc, .active = true } });
        dbg("vídeo de {d}: ssrc {d} (rtx {d})", .{ uid, ssrc, rtx });
        if (voz_video.watching() == uid) w.syncWatch(true);
    }

    /// Diz ao servidor quais SSRCs queremos receber (op 15) e pede quadro-chave
    /// dos novos. A lista vem da interface (a grade da call pode ter vários).
    fn syncWatch(w: *Worker, force: bool) void {
        var list: [voz_video.max_watch]u32 = @splat(0);
        const ssrcs = voz_video.watchSsrcs(if (w.v.kind == .stream) .stream else .voice, &list);
        var same = ssrcs.len == w.n_sub;
        if (same) {
            for (ssrcs, 0..) |s, i| {
                if (w.subs[i] == s) continue;
                same = false;
                break;
            }
        }
        if (!force and same) return;
        // Stream novo: o decodificador e as contas de qualidade recomeçam.
        if (ssrcs.len != w.n_sub or (ssrcs.len > 0 and w.n_sub > 0 and ssrcs[0] != w.subs[0])) {
            w.video_quality = 100;
            w.qcheck_ms = 0;
            w.remb_ms = 0;
            w.v_stat_ms = 0;
            w.v_have_seq = false;
            w.v_cycle = 0;
            w.v_ext_seq = 0;
        }
        for (ssrcs) |s| {
            var had = false;
            for (w.subs[0..w.n_sub]) |o| {
                if (o != s) continue;
                had = true;
                break;
            }
            if (!had) w.sendPli(s);
        }
        w.last_pli_ms = nowMs();
        // Quem saiu da lista é liberado pelo SSRC (sem tocar no resto do áudio).
        var removed: [voz_video.max_watch]u32 = undefined;
        var n_removed: usize = 0;
        for (w.subs[0..w.n_sub]) |old| {
            var keep = false;
            for (ssrcs) |s| if (s == old) {
                keep = true;
                break;
            };
            if (keep or old == 0 or n_removed == removed.len) continue;
            removed[n_removed] = old;
            n_removed += 1;
        }
        if (n_removed > 0) w.sendSinkRelease(removed[0..n_removed]);
        w.n_sub = 0;
        for (ssrcs) |s| {
            w.subs[w.n_sub] = s;
            w.n_sub += 1;
        }
        if (ssrcs.len > 0) w.sendSinkWants();
        if (ssrcs.len > 0) dbg("assistindo {d} ssrc(s) ({s}), primeiro {d}", .{ ssrcs.len, if (w.v.kind == .stream) "stream" else "voz", ssrcs[0] });
    }

    /// O SSRC principal (o primeiro da lista): é dele que saem perda, jitter e
    /// os relatórios RTCP. Os outros são só decodificados para a grade.
    fn primary(w: *const Worker) u32 {
        return if (w.n_sub > 0) w.subs[0] else 0;
    }

    /// Remontagem do SSRC: reaproveita a vaga dele ou pega uma livre.
    fn depFor(w: *Worker, ssrc: u32) *video_rtp.Depacketizer {
        for (w.deps[0..w.deps.len]) |*slot| {
            if (slot.ssrc == ssrc) return &slot.dep;
        }
        for (w.deps[0..w.deps.len]) |*slot| {
            if (slot.ssrc != 0) continue;
            slot.ssrc = ssrc;
            slot.dep.reset();
            return &slot.dep;
        }
        w.deps[0].ssrc = ssrc;
        w.deps[0].dep.reset();
        return &w.deps[0].dep;
    }

    fn sendSinkWants(w: *Worker) void {
        var list: [voz_video.max_watch]u32 = @splat(0);
        const ssrcs = voz_video.watchSsrcs(if (w.v.kind == .stream) .stream else .voice, &list);
        var b: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&b);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(fba.allocator());
        call_json.writeSinkWants(&out, fba.allocator(), ssrcs, w.video_quality, w.v.kind == .stream) catch return;
        _ = w.sendText(out.items);
    }

    /// Solta SSRCs específicos (nunca "any": 0 — no Discord isso calava o áudio
    /// da call junto).
    fn sendSinkRelease(w: *Worker, ssrcs: []const u32) void {
        var b: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&b);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(fba.allocator());
        out.appendSlice(fba.allocator(), "{\"op\":15,\"d\":{") catch return;
        for (ssrcs) |s| out.print(fba.allocator(), "\"{d}\":0,", .{s}) catch return;
        out.print(fba.allocator(), "\"any\":{d}}}", .{if (w.v.kind == .stream) @as(u8, 100) else 0}) catch return;
        _ = w.sendText(out.items);
    }

    /// RTCP PLI: o cabeçalho vai em claro e só o SSRC da mídia é cifrado, como
    /// no RTP "rtpsize" (mesmo contador de nonce).
    fn sendPli(w: *Worker, media: u32) void {
        if (!sys.valid(w.udp) or !w.have_secret) return;
        var plain: [12]u8 = undefined;
        _ = video_rtp.writePli(&plain, w.ssrc, media) orelse return;
        var buf: [8 + 4 + 16 + 4]u8 = undefined;
        @memcpy(buf[0..8], plain[0..8]);
        var nonce: [24]u8 = @splat(0);
        w.nonce +%= 1;
        std.mem.writeInt(u32, nonce[0..4], w.nonce, .big);
        var tag: [16]u8 = undefined;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.encrypt(buf[8..12], &tag, plain[8..12], buf[0..8], nonce, w.secret);
        @memcpy(buf[12..28], &tag);
        @memcpy(buf[28..32], nonce[0..4]);
        _ = sys.sendTo(w.udp, &buf, &w.server);
    }

    /// RTCP Transport Feedback (RTPFB, PT 205, FMT 15): um pacote recebido,
    /// delta pequeno. É o sinal que o controle de congestionamento do Discord
    /// usa para liberar bitrate.
    fn ccAdd(w: *Worker, seq: u16) void {
        if (!fb_cc or !w.have_secret) return;
        if (w.cc_n == w.cc_samples.len) w.flushTransportCc(nowMs());
        w.cc_samples[w.cc_n] = .{ .seq = seq, .us = @intCast(c.SDL_GetTicksNS() / 1000) };
        w.cc_n += 1;
    }

    /// Envia o lote: um RTCP a cada ~50 ms, como o Chrome, em vez de um por
    /// pacote (o SFU lia a enxurrada como perda atrás de perda).
    fn flushTransportCc(w: *Worker, now: i64) void {
        _ = now;
        if (w.cc_n == 0) return;
        const n = w.cc_n;
        w.cc_n = 0;
        if (!fb_cc or w.cc_media == 0 or !sys.valid(w.udp) or !w.have_secret) return;
        var plain: [1024]u8 = undefined;
        const p = video_rtp.writeTransportCc(&plain, w.ssrc, w.cc_media, w.cc_samples[0..n], w.cc_pkt) orelse return;
        w.cc_pkt +%= 1;
        var buf: [1044]u8 = undefined;
        @memcpy(buf[0..8], p[0..8]);
        var nonce: [24]u8 = @splat(0);
        w.nonce +%= 1;
        std.mem.writeInt(u32, nonce[0..4], w.nonce, .big);
        var tag: [16]u8 = undefined;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.encrypt(buf[8..p.len], &tag, p[8..p.len], p[0..8], nonce, w.secret);
        @memcpy(buf[p.len..][0..16], &tag);
        @memcpy(buf[p.len + 16 ..][0..4], nonce[0..4]);
        _ = sys.sendTo(w.udp, buf[0 .. p.len + 20], &w.server);
    }

    /// RTCP Receiver Report (PT 201): o SFU usa perda/jitter para estimar o
    /// canal e liberar mais bitrate. O cabeçalho (8 bytes) vai em claro; o
    /// bloco de relatório (24 bytes) é cifrado, como todo RTCP "rtpsize".
    fn sendRtcpRr(w: *Worker, media: u32) void {
        if (!fb_rr) return;
        if (!sys.valid(w.udp) or !w.have_secret or !w.v_have_seq) return;
        var plain: [32]u8 = undefined;
        const jitter: u32 = @intFromFloat(@max(w.v_jit, 0));
        const dlsr: u32 = if (w.sr_ms != 0)
            @intCast(@divTrunc((nowMs() - w.sr_ms) * 65536, 1000))
        else
            0;
        _ = video_rtp.writeRr(&plain, w.ssrc, media, w.v_ext_seq, jitter, w.sr_lsr, dlsr) orelse return;
        var buf: [8 + 24 + 16 + 4]u8 = undefined;
        @memcpy(buf[0..8], plain[0..8]);
        var nonce: [24]u8 = @splat(0);
        w.nonce +%= 1;
        std.mem.writeInt(u32, nonce[0..4], w.nonce, .big);
        var tag: [16]u8 = undefined;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.encrypt(buf[8..32], &tag, plain[8..32], buf[0..8], nonce, w.secret);
        @memcpy(buf[32..48], &tag);
        @memcpy(buf[48..52], nonce[0..4]);
        _ = sys.sendTo(w.udp, &buf, &w.server);
    }

    /// RTCP REMB (PT 206): diz quanto cabe no nosso enlace. O SFU/remetente
    /// pode então soltar um bitrate maior que o mínimo.
    fn sendRemb(w: *Worker, media: u32, bitrate: u32) void {
        if (!fb_remb) return;
        if (!sys.valid(w.udp) or !w.have_secret) return;
        var plain: [24]u8 = undefined;
        _ = video_rtp.writeRemb(&plain, w.ssrc, media, bitrate) orelse return;
        var buf: [8 + 16 + 16 + 4]u8 = undefined;
        @memcpy(buf[0..8], plain[0..8]);
        var nonce: [24]u8 = @splat(0);
        w.nonce +%= 1;
        std.mem.writeInt(u32, nonce[0..4], w.nonce, .big);
        var tag: [16]u8 = undefined;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.encrypt(buf[8..24], &tag, plain[8..24], buf[0..8], nonce, w.secret);
        @memcpy(buf[24..40], &tag);
        @memcpy(buf[40..44], nonce[0..4]);
        _ = sys.sendTo(w.udp, &buf, &w.server);
    }

    // --- DAVE --------------------------------------------------------------

    fn initDave(w: *Worker, version: u16) void {
        var d = Dave.init(w.v.dave_group, w.v.user, version) orelse {
            std.log.warn("voz: DAVE indisponível", .{});
            return;
        };
        d.setLocalSsrc(w.ssrc);
        var ui = w.call_users.keyIterator();
        while (ui.next()) |u| d.addUser(u.*);
        var si = w.call_ssrcs.iterator();
        while (si.next()) |kv| d.setSsrcUser(kv.key_ptr.*, kv.value_ptr.*);
        // Vídeo anunciado antes de o DAVE nascer (o op 12 pode vir antes do op 4).
        var vi = w.video_users.iterator();
        while (vi.next()) |kv| d.setSsrcUser(kv.value_ptr.*, kv.key_ptr.*);
        w.dave = d;
    }

    fn sendKeyPackage(w: *Worker) void {
        const dave = if (w.dave) |*d| d else return;
        var kp: [4096]u8 = undefined;
        const n = dave.keyPackage(&kp);
        if (n > 0) _ = w.sendBinary(26, kp[0..n]);
    }

    // --- UDP / mídia -------------------------------------------------------

    fn readUdp(w: *Worker) void {
        if (!sys.valid(w.udp)) return;
        // No máximo 64 pacotes por volta: o resto fica para a próxima.
        for (0..64) |_| {
            var buf: [2048]u8 = undefined;
            const nr = sys.recvNow(w.udp, &buf);
            if (nr <= 0) return;
            w.onRtp(buf[0..@intCast(nr)]);
        }
    }

    /// Lê 20 ms do microfone; manda só enquanto há voz (ou a tecla do aperte
    /// para falar), mais 5 quadros de silêncio no fim, como o cliente oficial,
    /// e nada quando mudo, por nós ou pelo servidor.
    fn sendFrame(w: *Worker, now: i64) void {
        if (w.v.kind == .stream) return;
        const sh = &voz_audio.sh;
        const blocked = w.v.micBlocked();
        var pcm: [frame_samples * channels]i16 = undefined;
        const have = !blocked and w.mic.read(&pcm);
        const ptt = sh.ptt.load(.monotonic);
        const key = voz_audio.pttKey();
        // Aperte para falar com a tecla solta: o microfone segue sendo lido (o
        // som velho não pode sair quando a tecla descer), mas nada é tratado.
        const idle = w.talk.pttIdle(now, ptt, key);
        // Mudo não gasta nada com o supressor: nem o estado fica.
        if (blocked or w.mic.stream == null or idle) w.cap.release();
        var voice = false;
        if (have and !idle) {
            const res = w.cap.process(&pcm, sh.captureCfg());
            voice = res.voice;
            w.mic_peak_rms = @max(w.mic_peak_rms, res.rms);
        }
        const talking = w.talk.update(now, .{
            .voice = voice,
            .ptt = ptt,
            .key = key,
            .blocked = blocked or w.mic.stream == null,
        });
        if (debugOn() and now - w.stats_ms >= 3000) {
            dbg("recebido: {d} pacotes de {d} pessoas, fora de ordem {d}, perdidos refeitos {d}, inventados {d}, fila vazia {d}, pausas de quem fala {d}, maior vão {d} ms, descartados {d}, recomeços {d}, sem decifrar {d}; thread: acordou atrasada até {d} ms, ocupada até {d} ms", .{ w.stats.packets, w.n_sources, w.stats.late, w.stats.rebuilt, w.stats.concealed, w.stats.starved, w.stats.paused, w.stats.gap_max_ms, w.stats.skipped, w.stats.cleared, w.stats.undecrypted, w.stats.wake_late_ms, w.stats.busy_ms });
            dbg("extra: com padding {d}, silêncios decodificados {d}, quadros quase no limite {d}, mistura estourou {d} amostras", .{ w.stats.padded, w.stats.silence_frames, w.stats.near_full, mix_over.swap(0, .monotonic) });
            dbg("fila: seca {d} vezes no meio da fala (cada uma ~20 ms de corte), maior {d} ms, vãos de 60 ms ou mais {d}, voltas logo depois do silêncio {d}", .{ w.stats.dry, w.stats.queue_max_ms, w.stats.net_gaps, w.stats.resumed });
            w.stats = .{};
            dbg("mic: {s}, rms máx {d:.0}, {d} quadros enviados, DAVE {s}", .{ if (w.mic.stream == null) "sem microfone" else if (blocked) "mudo" else "ligado", w.mic_peak_rms, w.sent_frames, if (w.dave) |dv| (if (dv.enabled) "cifrando" else "esperando") else "não" });
            w.stats_ms = now;
            w.mic_peak_rms = 0;
        }
        if (talking != w.speaking_now) {
            dbg("falando: {}", .{talking});
            w.speaking_now = talking;
            if (talking) w.spurt_start = true;
            w.setSpeaking(talking);
            w.speaking_emit_ms = now;
            if (!talking) w.trailing_silence = 5;
        } else if (talking and now - w.speaking_emit_ms >= 1000) {
            // O anel apaga sozinho depois de 4 s sem notícia (Store.isSpeaking).
            w.setSpeaking(true);
            w.speaking_emit_ms = now;
        }
        if (!talking) {
            if (w.trailing_silence > 0) {
                w.trailing_silence -= 1;
                w.sendOpus(&silence);
            }
            return;
        }
        // Falando, mas o microfone ainda não entregou este quadro: não é pausa
        // na fala; vem no próximo tique.
        if (!have) return;
        const enc = w.encoder orelse return;
        var packet: [1500]u8 = undefined;
        const len = c.opus_encode(enc, &pcm, frame_samples, &packet, packet.len);
        if (len <= 0) return;
        w.sendOpus(packet[0..@intCast(len)]);
    }

    fn sendOpus(w: *Worker, frame: []const u8) void {
        var payload = frame;
        var dave_buf: [2048]u8 = undefined;
        if (w.dave) |*dave| if (dave.enabled and !std.mem.eql(u8, frame, &silence)) {
            const n = dave.encrypt(w.ssrc, frame, &dave_buf);
            if (n == 0) return;
            payload = dave_buf[0..n];
        };
        w.sendRtp(payload);
    }

    /// O anel verde em volta da gente. O Discord não precisa saber de cada
    /// fala: o op 5 vai uma vez só, quando a sessão abre (como o cliente
    /// oficial); mandar "parei" fazia o servidor descartar o começo
    /// da próxima fala, que chega pelo UDP antes do "voltei" pelo WebSocket.
    fn setSpeaking(w: *Worker, on: bool) void {
        if (w.v.kind == .stream) return;
        w.v.emit(.{ .voice_speaking = .{ .user = w.v.user, .speaking = on } });
    }

    /// Op 5: "este SSRC manda áudio de microfone". Um espectador de stream não
    /// manda mídia nenhuma.
    fn announceSpeaking(w: *Worker) void {
        if (w.v.kind == .stream) return;
        var b: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{{\"op\":5,\"d\":{{\"speaking\":1,\"delay\":0,\"ssrc\":{d}}}}}", .{w.ssrc}) catch return;
        _ = w.sendText(p);
    }

    fn sendRtp(w: *Worker, payload: []const u8) void {
        if (!sys.valid(w.udp) or payload.len == 0 or !w.have_secret) return;
        var buf: [12 + 2048 + 16 + 4]u8 = undefined;
        const off = 12;
        if (payload.len + off + 16 + 4 > buf.len) return;
        buf[0] = 0x80;
        // Payload 120 (Opus); o bit de marcação abre cada fala.
        buf[1] = if (w.spurt_start) 0xF8 else 0x78;
        w.spurt_start = false;
        std.mem.writeInt(u16, buf[2..4], w.rtp_seq, .big);
        std.mem.writeInt(u32, buf[4..8], w.rtp_ts, .big);
        std.mem.writeInt(u32, buf[8..12], w.ssrc, .big);
        var nonce: [24]u8 = @splat(0);
        w.nonce +%= 1;
        std.mem.writeInt(u32, nonce[0..4], w.nonce, .big);
        var tag: [16]u8 = undefined;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.encrypt(buf[off..][0..payload.len], &tag, payload, buf[0..off], nonce, w.secret);
        @memcpy(buf[off + payload.len ..][0..16], &tag);
        @memcpy(buf[off + payload.len + 16 ..][0..4], nonce[0..4]);
        const total = off + payload.len + 16 + 4;
        const rc = sys.sendTo(w.udp, buf[0..total], &w.server);
        if (rc < 0) dbg("sendto falhou", .{}) else w.sent_frames += 1;
        w.rtp_seq +%= 1;
    }

    /// RTP de vídeo: decifra, tira as extensões, remonta o H.264 e, se for o
    /// stream assistido, manda o quadro inteiro para a thread de decodificação.
    fn onVideoRtp(w: *Worker, buf: []const u8) void {
        if (!w.have_secret) return;
        const h = video_rtp.parseHeader(buf) orelse return;
        if (!voz_video.isWatched(h.ssrc)) {
            // Outra camada/stream a chegar: mostra uma vez, sem decodificar.
            var known = false;
            for (w.v_seen) |s| {
                if (s == h.ssrc) {
                    known = true;
                    break;
                }
            }
            if (!known) {
                var i: usize = 0;
                while (i < w.v_seen.len) : (i += 1) {
                    if (w.v_seen[i] == 0) {
                        w.v_seen[i] = h.ssrc;
                        break;
                    }
                }
                dbg("vídeo de outro ssrc {d} (não assistido)", .{h.ssrc});
            }
            return;
        }
        const is_primary = h.ssrc == w.primary();
        if (is_primary) {
            w.v_pkts +%= 1;
            // Jitter RFC 3550 (A.8) para o Receiver Report: chegada (relógio de
            // 90 kHz) menos carimbo do pacote, suavizado.
            const arr_us: u64 = @intCast(c.SDL_GetTicksNS() / 1000);
            if (w.v_jit_have and arr_us > w.v_jit_arr_us) {
                const dt_rtp: f64 = @floatFromInt(@as(i32, @bitCast(h.ts -% w.v_jit_ts)));
                const dt_arr: f64 = @as(f64, @floatFromInt(arr_us - w.v_jit_arr_us)) * 90.0 / 1_000_000.0;
                w.v_jit += (@abs(dt_arr - dt_rtp) - w.v_jit) / 16.0;
            }
            w.v_jit_ts = h.ts;
            w.v_jit_arr_us = arr_us;
            w.v_jit_have = true;
        }
        // Para o RTCP Receiver Report: sequência estendida (o contador de 16
        // bits dá a volta) e o pacote mais alto que chegou. Pacote atrasado
        // (fora de ordem) não mexe no maior.
        if (is_primary) {
            const forward = !w.v_have_seq or (h.seq -% w.v_last_seq) < 0x8000;
            if (forward) {
                if (w.v_have_seq and h.seq < w.v_last_seq) w.v_cycle +%= 1;
                w.v_last_seq = h.seq;
                w.v_have_seq = true;
                const ext: u32 = (@as(u32, w.v_cycle) << 16) | h.seq;
                if (ext > w.v_ext_seq) w.v_ext_seq = ext;
            }
        }
        if (buf.len < h.aad_len + 20) return;
        const cipher = buf[h.aad_len .. buf.len - 20];
        voz_video.noteBytes(cipher.len);
        if (cipher.len > 2048) return;
        var tag: [16]u8 = undefined;
        @memcpy(&tag, buf[buf.len - 20 ..][0..16]);
        var nonce: [24]u8 = @splat(0);
        @memcpy(nonce[0..4], buf[buf.len - 4 ..]);
        var plain: [2048]u8 = undefined;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.decrypt(plain[0..cipher.len], cipher, tag, buf[0..h.aad_len], nonce, w.secret) catch return;
        var end = cipher.len;
        if (h.padding) {
            if (end == 0 or plain[end - 1] == 0 or plain[end - 1] > end) return;
            end -= plain[end - 1];
        }
        if (h.ext_len > end) return;
        if (h.ext_len > 0) {
            if (video_rtp.transportSeq(plain[0..h.ext_len])) |tseq| {
                w.cc_media = h.ssrc;
                w.ccAdd(tseq);
            } else if (debugOn() and !w.cc_missing) {
                w.cc_missing = true;
                dbg("extensão transport-cc (id 5) ausente nos pacotes de vídeo", .{});
            }
        } else if (debugOn() and !w.cc_missing) {
            w.cc_missing = true;
            dbg("pacotes de vídeo sem extensões RTP (transport-cc não vai)", .{});
        }
        const payload = plain[h.ext_len..end];
        if (payload.len == 0) return;
        const dep = w.depFor(h.ssrc);
        const complete = dep.feed(alloc, payload, h.ts, h.seq, h.marker) catch {
            dep.reset();
            return;
        };
        if (!complete) return;
        // Daqui para baixo são diagnósticos: contam só o stream principal.
        if (is_primary) {
            if (dep.key) w.v_keys +%= 1;
            // Intervalo entre os carimbos de tempo dos quadros: o fps que o
            // encoder produziu. Se for 60 e decodificarmos 40, quem perdeu
            // quadros foi o caminho (SFU), não o encoder.
            if (w.v_have_ts) {
                const d = dep.ts -% w.v_last_ts;
                if (d > 0 and d < 90000) {
                    if (d < w.v_ts_min) w.v_ts_min = d;
                    if (d > 2500) w.v_ts_big +%= 1; // > 27 ms: faltou quadro no meio
                }
            }
            w.v_last_ts = dep.ts;
            w.v_have_ts = true;
            // Intervalo entre quadros: se o SFU manda em rajadas, a imagem
            // "trava" e depois corre, mesmo com 60/s na média.
            const t_frame = nowMs();
            if (w.v_last_frame_ms != 0) {
                const gap = t_frame - w.v_last_frame_ms;
                if (gap > w.v_gap_max) w.v_gap_max = gap;
                // Histograma: um stream "liso" tem quase tudo abaixo de 20 ms.
                if (gap < 20) {
                    w.v_gap_hist[0] += 1;
                } else if (gap < 40) {
                    w.v_gap_hist[1] += 1;
                } else if (gap < 80) {
                    w.v_gap_hist[2] += 1;
                } else {
                    w.v_gap_hist[3] += 1;
                }
            }
            w.v_last_frame_ms = t_frame;
        }
        var frame: []const u8 = dep.frame();
        // Marcador 0xFAFA no fim: o quadro veio cifrado pelo DAVE. Sem ele é
        // H.264 puro (call sem E2EE ou no meio de uma transição).
        if (frame.len >= 2 and frame[frame.len - 1] == 0xFA and frame[frame.len - 2] == 0xFA) {
            const dave = if (w.dave) |*d| d else {
                dep.consumed();
                return;
            };
            const need = frame.len + 512;
            if (w.video_plain.items.len < need) {
                w.video_plain.resize(alloc, need) catch {
                    dep.consumed();
                    return;
                };
            }
            const n = dave.decrypt(c.DAVE_MEDIA_TYPE_VIDEO, h.ssrc, 0, frame, w.video_plain.items) orelse {
                w.stats.undecrypted += 1;
                dep.consumed();
                return;
            };
            frame = w.video_plain.items[0..n];
        }
        voz_video.push(h.ssrc, frame);
        dep.consumed();
    }

    /// RTCP que chega do SFU: só o Sender Report interessa — dele saem o LSR e
    /// o DLSR (RTT) do nosso Receiver Report. O começo vai em claro; o resto é
    /// cifrado como no RTP.
    fn onRtcp(w: *Worker, buf: []const u8) void {
        if (!w.have_secret or buf.len < 8 + 20) return;
        if ((buf[0] >> 6) != 2) return;
        if (buf[1] != 200) return; // Sender Report
        const body = buf[8 .. buf.len - 20];
        if (body.len < 20 or body.len > 512) return;
        var plain: [512]u8 = undefined;
        var tag: [16]u8 = undefined;
        @memcpy(&tag, buf[buf.len - 20 ..][0..16]);
        var nonce: [24]u8 = @splat(0);
        @memcpy(nonce[0..4], buf[buf.len - 4 ..]);
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.decrypt(plain[0..body.len], body, tag, buf[0..8], nonce, w.secret) catch return;
        // plain[0..4] = NTP (parte inteira), plain[4..8] = fração.
        const ntp_msw = std.mem.readInt(u32, plain[0..4], .big);
        const ntp_lsw = std.mem.readInt(u32, plain[4..8], .big);
        w.sr_lsr = (ntp_msw << 16) | (ntp_lsw >> 16);
        w.sr_ms = nowMs();
    }

    fn onRtp(w: *Worker, buf: []const u8) void {
        if (buf.len < 12) return;
        if ((buf[0] >> 6) != 2) return;
        // RTCP divide o socket com o RTP: por enquanto só os relatórios do
        // servidor (não usamos) e o nosso PLI importam.
        if (video_rtp.isRtcp(buf)) {
            w.onRtcp(buf);
            return;
        }
        const pt = buf[1] & 0x7f;
        if (pt != opus_pt) {
            // O SFU pode renumerar o payload type do vídeo: quem decide é o
            // SSRC assistido (o RTX usa outro SSRC e cai fora).
            w.onVideoRtp(buf);
            return;
        }
        if (!w.have_secret) return;
        if (buf.len < 12 + 16 + 4) return;
        const ssrc = std.mem.readInt(u32, buf[8..12], .big);
        if (ssrc == w.ssrc) return;
        // Nos modos "rtpsize" só o cabeçalho fixo, os CSRC e os 4 bytes do
        // cabeçalho da extensão vão em claro; o corpo da extensão vai
        // cifrado junto com o áudio e sai depois de decifrar.
        var aad_len: usize = 12 + @as(usize, buf[0] & 0x0f) * 4;
        var ext_words: usize = 0;
        if (buf[0] & 0x10 != 0) {
            if (aad_len + 4 > buf.len) return;
            ext_words = std.mem.readInt(u16, buf[aad_len + 2 ..][0..2], .big);
            aad_len += 4;
        }
        if (buf.len < aad_len + 16 + 4) return;
        const cipher = buf[aad_len .. buf.len - 20];
        var tag: [16]u8 = undefined;
        @memcpy(&tag, buf[buf.len - 20 ..][0..16]);
        var nonce: [24]u8 = @splat(0);
        @memcpy(nonce[0..4], buf[buf.len - 4 ..]);
        var plain: [2048]u8 = undefined;
        if (cipher.len > plain.len) return;
        const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
        aead.decrypt(plain[0..cipher.len], cipher, tag, buf[0..aad_len], nonce, w.secret) catch return;
        // With the padding bit set, the last byte counts the padding bytes that
        // end the (encrypted) payload. Left on, they hide the DAVE 0xFAFA
        // marker and the ciphertext goes to the Opus decoder.
        var end = cipher.len;
        if (buf[0] & 0x20 != 0) {
            w.stats.padded += 1;
            if (end == 0 or plain[end - 1] == 0 or plain[end - 1] > end) return;
            end -= plain[end - 1];
        }
        if (ext_words * 4 > end) return;
        // O mesmo transporte leva áudio e vídeo: o feedback em lote cobre a
        // faixa inteira, então os pacotes de áudio precisam entrar também —
        // sem isso o SFU lê cada um deles como perdido.
        if (ext_words > 0) {
            if (video_rtp.transportSeq(plain[0 .. ext_words * 4])) |tseq| w.ccAdd(tseq);
        }
        var frame: []const u8 = plain[ext_words * 4 .. end];
        if (frame.len == 0) return;
        // No stream (Go Live) não há op 5 dizendo quem fala: o dono é o do
        // stream, e é ele que o DAVE precisa para achar a chave do áudio.
        const uid: Id = if (w.v.kind == .stream) w.v.user else 0;
        const src = w.sourceFor(ssrc, uid) orelse return;
        const seq = std.mem.readInt(u16, buf[2..4], .big);
        const ts = std.mem.readInt(u32, buf[4..8], .big);
        if (std.mem.eql(u8, frame, &silence)) {
            // Passa pelo decodificador: ele prevê o volume de cada quadro a partir do anterior.
            // Sem isto, a próxima fala pode sair muitas vezes mais alta por uns 100 ms.
            var quiet: [5760 * channels]i16 = undefined;
            const qn = c.opus_decode(src.dec, frame.ptr, @intCast(frame.len), &quiet, 5760, 0);
            w.stats.silence_frames += 1;
            // E toca: quem volta a falar logo depois encontra a folga na fila.
            const st = if (w.deaf_applied) null else src.stream;
            if (src.jitter.silenceFrame(seq, ts, if (st) |s| queuedMs(s) else 0) and qn > 0) {
                if (st) |s| src.put(s, quiet[0..@as(usize, @intCast(qn)) * channels]);
            } else src.seam.dropped();
            return;
        }
        // Quadro do DAVE (termina com o marcador 0xFAFA): decifra. Sem o
        // marcador é Opus puro (call sem E2EE ou no meio de uma transição).
        var dave_out: [2048]u8 = undefined;
        if (frame.len >= 2 and frame[frame.len - 1] == 0xFA and frame[frame.len - 2] == 0xFA) {
            const dave = if (w.dave) |*d| d else return;
            const n = dave.decrypt(c.DAVE_MEDIA_TYPE_AUDIO, ssrc, src.user, frame, &dave_out) orelse {
                w.stats.undecrypted += 1;
                return;
            };
            frame = dave_out[0..n];
        }
        w.play(src, frame, seq, ts);
    }

    // --- Áudio ------------------------------------------------------------

    const spec: c.SDL_AudioSpec = voz_audio.spec;

    fn initAudio(w: *Worker) bool {
        var err: c_int = 0;
        w.encoder = c.opus_encoder_create(opus_rate, channels, c.OPUS_APPLICATION_VOIP, &err);
        if (err == c.OPUS_OK) {
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_BITRATE_REQUEST, @as(c_int, 64000));
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, 5));
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_INBAND_FEC_REQUEST, @as(c_int, 1));
            _ = c.opus_encoder_ctl(w.encoder, c.OPUS_SET_PACKET_LOSS_PERC_REQUEST, @as(c_int, 10));
        } else w.encoder = null;
        if (voz_audio.acquire()) {
            w.audio_on = true;
            const now = nowMs();
            w.out.open(now);
            w.updatePull();
            // Espectador de stream só ouve (o som do stream, se houver).
            if (w.v.kind == .voice) {
                w.mic.paused = w.v.micBlocked();
                w.mic.open(now);
            }
        }
        w.applyAudioFlags();
        w.reportAudio();
        return w.out.dev != 0 or w.mic.stream != null;
    }

    /// Mudo desliga o microfone de verdade; ensurdecer pausa a saída.
    fn applyAudioFlags(w: *Worker) void {
        w.mic.setPaused(w.v.micBlocked());
        const deaf = w.v.outBlocked();
        if (w.out.dev != 0 and deaf != w.deaf_applied) {
            if (deaf) _ = c.SDL_PauseAudioDevice(w.out.dev) else _ = c.SDL_ResumeAudioDevice(w.out.dev);
            for (w.sources[0..w.n_sources]) |*s| if (s.stream) |st| {
                _ = c.SDL_ClearAudioStream(st);
            };
            w.deaf_applied = deaf;
        }
        const gen = w.v.volumes_gen.load(.acquire);
        if (gen != w.volumes_gen) {
            w.volumes_gen = gen;
            for (w.sources[0..w.n_sources]) |*s| s.applyGain(w.v);
        }
    }

    /// Dispositivo escolhido mudou, sumiu ou voltou, em plena call: reabre o
    /// microfone e passa cada pessoa para a saída nova. A conexão nem percebe.
    fn audioPoll(w: *Worker, now: i64) void {
        if (!w.audio_on) return;
        w.mic.check(now);
        w.out.applyGain();
        if (w.out.check(now)) |dev| {
            for (w.sources[0..w.n_sources]) |*s| {
                if (s.stream == null) s.stream = c.SDL_CreateAudioStream(&spec, &spec);
                if (s.stream) |st| voz_audio.Output.rebind(dev, st);
            }
            w.out.adopt(dev);
            w.updatePull();
            // Era um dispositivo novo, ainda sem a pausa do ensurdecer.
            if (w.deaf_applied) _ = c.SDL_PauseAudioDevice(dev);
        }
        w.reportAudio();
    }

    /// Avisa a interface quando o microfone ou a saída mudam de situação: ela
    /// mostra na barra de voz, em vez de ficar calada sem explicação.
    fn reportAudio(w: *Worker) void {
        if (w.v.kind == .stream) return;
        const mic_ok = !w.mic.failed();
        const out_ok = w.out.dev != 0;
        if (mic_ok == w.mic_ok_sent and out_ok == w.out_ok_sent) return;
        w.mic_ok_sent = mic_ok;
        w.out_ok_sent = out_ok;
        w.v.emit(.{ .voice_audio = .{ .mic_ok = mic_ok, .out_ok = out_ok } });
    }

    fn sourceFor(w: *Worker, ssrc: u32, user: Id) ?*Source {
        for (w.sources[0..w.n_sources]) |*s| if (s.ssrc == ssrc) {
            if (user != 0 and s.user != user) {
                s.user = user;
                s.applyGain(w.v);
            }
            return s;
        };
        if (w.n_sources == w.sources.len) return null;
        var err: c_int = 0;
        const dec = c.opus_decoder_create(opus_rate, channels, &err) orelse return null;
        if (err != c.OPUS_OK) {
            c.opus_decoder_destroy(dec);
            return null;
        }
        var src: Source = .{ .ssrc = ssrc, .user = user, .dec = dec };
        src.jitter.pull_ms = w.pull_ms;
        if (w.out.dev != 0) {
            src.stream = c.SDL_CreateAudioStream(&spec, &spec);
            if (src.stream) |st| _ = c.SDL_BindAudioStream(w.out.dev, st);
        }
        w.sources[w.n_sources] = src;
        w.n_sources += 1;
        const s = &w.sources[w.n_sources - 1];
        s.applyGain(w.v);
        return s;
    }

    fn removeSource(w: *Worker, user: Id) void {
        var i: usize = 0;
        while (i < w.n_sources) {
            if (w.sources[i].user == user) {
                w.sources[i].deinit();
                w.sources[i] = w.sources[w.n_sources - 1];
                w.n_sources -= 1;
            } else i += 1;
        }
    }

    /// Opus -> PCM -> o stream da pessoa (o SDL mistura e toca).
    fn play(w: *Worker, src: *Source, frame: []const u8, seq: u16, ts: u32) void {
        const now = nowMs();
        // Começo de uma fala (silêncio antes): a fila do SDL recomeça com
        // uma folga contra o jitter. No meio da fala nunca entra silêncio.
        const since = now - src.last_ms;
        const spurt = since > 250;
        if (!src.speaking or now - src.last_emit_ms > 1000) {
            src.speaking = true;
            src.last_emit_ms = now;
            if (src.user != 0 and w.v.kind == .voice) w.v.emit(.{ .voice_speaking = .{ .user = src.user, .speaking = true } });
        }
        src.last_ms = now;
        w.stats.packets += 1;
        if (w.deaf_applied) {
            src.jitter.last_seq = seq;
            src.jitter.last_ts = ts;
            return;
        }
        const st = src.stream orelse return;
        const queued_ms = queuedMs(st);
        const prev_seq = src.jitter.last_seq;
        const prev_ts = src.jitter.last_ts;
        const invented = src.jitter.concealed;
        const plan = src.jitter.plan(seq, ts, spurt, queued_ms);
        // Vão no meio da fala que não é silêncio nem pausa dele: a rede (ou quem
        // manda) segurou os pacotes.
        if (!spurt and !plan.resumed and !plan.paused) {
            w.stats.gap_max_ms = @max(w.stats.gap_max_ms, since);
            if (since >= 60) w.stats.net_gaps += 1;
            if (since >= 80 and !plan.late) dbg("vão na rede: ssrc {d}, {d} ms sem pacote, sequência +{d}, relógio +{d} quadros, fila com {d} ms, {d} inventados", .{ src.ssrc, since, seq -% prev_seq, (ts -% prev_ts) / frame_samples, queued_ms, invented });
        }
        if (plan.resumed) w.stats.resumed += 1;
        if (plan.late) {
            w.stats.late += 1;
            return;
        }
        if (plan.clear) {
            w.stats.cleared += 1;
            _ = c.SDL_ClearAudioStream(st);
            src.seam.dropped();
        }
        if (plan.gap) src.seam.dropped();
        if (plan.paused) w.stats.paused += 1;
        // Depois de uma pausa ou de um buraco grande, o estado dele é de outra hora.
        if (spurt or plan.fresh) _ = c.opus_decoder_ctl(src.dec, c.OPUS_RESET_STATE);
        if (!spurt and !plan.clear and !plan.paused and !plan.resumed and queued_ms == 0) w.stats.starved += 1;
        if (plan.pad_ms > 0) {
            const silence_buf: [voz.Jitter.cushion_max * bytes_per_ms]u8 = @splat(0);
            var left: usize = plan.pad_ms * bytes_per_ms;
            while (left > 0) {
                const n = @min(left, silence_buf.len);
                _ = c.SDL_PutAudioStreamData(st, &silence_buf, @intCast(n));
                left -= n;
            }
            src.seam.silence();
        }
        // O que se perdeu vem antes deste pacote, para o ouvido e para o Opus: o
        // decodificador continua de onde parou, e fora de ordem a emenda estala.
        if (plan.lost > 0) {
            w.stats.rebuilt += plan.lost;
            var fill: [frame_samples * channels]i16 = undefined;
            for (0..plan.lost) |i| {
                // O último dá para recuperar do próprio pacote (FEC do Opus);
                // sem esses dados, ele faz o mesmo que os outros: inventa.
                const fec = i + 1 == plan.lost;
                const m = c.opus_decode(src.dec, if (fec) frame.ptr else null, if (fec) @intCast(frame.len) else 0, &fill, frame_samples, @intFromBool(fec));
                if (m > 0) src.put(st, fill[0..@as(usize, @intCast(m)) * channels]);
            }
        }
        var pcm: [5760 * channels]i16 = undefined;
        const n = c.opus_decode(src.dec, frame.ptr, @intCast(frame.len), &pcm, 5760, 0);
        if (n <= 0) return;
        if (debugOn()) w.noteLevel(src, pcm[0..@as(usize, @intCast(n)) * channels], since, spurt, plan, frame);
        if (plan.skip) {
            w.stats.skipped += 1;
            src.seam.dropped();
            return;
        }
        src.put(st, pcm[0..@as(usize, @intCast(n)) * channels]);
    }

    /// Com a depuração ligada: o estalo some na média de 3 s, então o salto vai para o registro
    /// na hora, com o que pode explicar ele.
    fn noteLevel(w: *Worker, src: *Source, pcm: []const i16, since: i64, spurt: bool, plan: voz.Jitter.Plan, frame: []const u8) void {
        var peak: i32 = 0;
        for (pcm) |v| peak = @max(peak, @as(i32, @intCast(@abs(@as(i32, v)))));
        if (peak >= 32000) w.stats.near_full += 1;
        const now = nowMs();
        // Sílaba forte depois de uma fraca é normal: só o que passa bem disso.
        if (peak >= 16000 and peak > src.peak_prev * 4 and now - src.jump_ms >= 200) {
            src.jump_ms = now;
            dbg("salto de volume: ssrc {d}, pessoa {d}: pico {d} -> {d}, {d} bytes, TOC {x:0>2}, {d} ms sem pacote, perdidos {d}, começo de fala {}, pausa {}", .{ src.ssrc, src.user, src.peak_prev, peak, frame.len, frame[0], since, plan.lost, spurt, plan.paused });
        }
        src.peak_prev = peak;
    }

    /// A fila de alguém seca antes da próxima volta: em vez de um corte seco no
    /// meio da onda, o Opus inventa e vai se apagando.
    fn conceal(w: *Worker) void {
        if (w.deaf_applied) return;
        for (w.sources[0..w.n_sources]) |*s| {
            if (s.jitter.ended) continue;
            const st = s.stream orelse continue;
            const what = s.jitter.conceal(queuedMs(st));
            if (what == .none) continue;
            var fill: [frame_samples * channels]i16 = undefined;
            const m = c.opus_decode(s.dec, null, 0, &fill, frame_samples, 0);
            if (m <= 0) continue;
            w.stats.concealed += 1;
            const pcm = fill[0..@as(usize, @intCast(m)) * channels];
            if (what == .last) {
                s.seam.fadeOut(pcm);
                _ = c.SDL_PutAudioStreamData(st, pcm.ptr, @intCast(pcm.len * @sizeOf(i16)));
            } else s.put(st, pcm);
        }
    }

    /// Só com a depuração, a cada 20 ms: a fila de quem está falando. Seca no meio
    /// da fala é o corte que se ouve; cheia demais é atraso.
    fn watchQueues(w: *Worker) void {
        if (w.deaf_applied) return;
        for (w.sources[0..w.n_sources]) |*s| {
            if (!s.speaking or s.jitter.ended) continue;
            const st = s.stream orelse continue;
            const q = queuedMs(st);
            if (q == 0) w.stats.dry += 1;
            w.stats.queue_max_ms = @max(w.stats.queue_max_ms, q);
        }
    }

    /// De quanto em quanto o dispositivo puxa áudio de cada stream.
    fn updatePull(w: *Worker) void {
        var fmt: c.SDL_AudioSpec = undefined;
        var frames: c_int = 0;
        if (w.out.dev == 0 or !c.SDL_GetAudioDeviceFormat(w.out.dev, &fmt, &frames) or frames <= 0 or fmt.freq <= 0) return;
        w.pull_ms = @intCast(@divTrunc(frames * 1000, fmt.freq) + 1);
        dbg("saída: {d} Hz, {d} quadros de cada vez ({d} ms)", .{ fmt.freq, frames, w.pull_ms });
        if (debugOn()) _ = c.SDL_SetAudioPostmixCallback(w.out.dev, mixCheck, null);
        for (w.sources[0..w.n_sources]) |*s| s.jitter.pull_ms = w.pull_ms;
    }

    /// Quem parou de mandar áudio há 300 ms parou de falar (o anel apaga).
    fn expireSpeakers(w: *Worker, now: i64) void {
        for (w.sources[0..w.n_sources]) |*s| if (s.speaking and now - s.last_ms > 400) {
            s.speaking = false;
            if (s.user != 0 and w.v.kind == .voice) w.v.emit(.{ .voice_speaking = .{ .user = s.user, .speaking = false } });
        };
    }
};

/// Amostras da mistura final fora de -1..1 (o SDL corta seco): a soma das vozes estourou.
var mix_over: std.atomic.Value(u32) = .init(0);

fn mixCheck(_: ?*anyopaque, _: [*c]const c.SDL_AudioSpec, buffer: [*c]f32, buflen: c_int) callconv(.c) void {
    const n: usize = @intCast(@divTrunc(buflen, @sizeOf(f32)));
    var over: u32 = 0;
    for (buffer[0..n]) |v| {
        if (@abs(v) > 1) over += 1;
    }
    if (over > 0) _ = mix_over.fetchAdd(over, .monotonic);
}

/// O que aconteceu com o áudio desde o último relatório (LARPER_VOICE_DEBUG=1).
const Stats = struct {
    packets: u32 = 0,
    late: u32 = 0,
    rebuilt: u32 = 0,
    starved: u32 = 0,
    /// Quem fala parou de mandar um pouco: não é culpa da rede.
    paused: u32 = 0,
    /// Quadros inventados porque a fila ia secar.
    concealed: u32 = 0,
    /// O maior tempo entre dois pacotes da mesma pessoa, dentro de uma fala, sem
    /// contar o silêncio e as pausas dela.
    gap_max_ms: i64 = 0,
    /// Vãos de 60 ms ou mais dentro de uma fala (o que a rede segurou).
    net_gaps: u32 = 0,
    /// Voltas logo depois dos quadros de silêncio (fala nova, com folga).
    resumed: u32 = 0,
    /// Vezes, a cada 20 ms, que a fila de quem falava estava seca: corte audível.
    dry: u32 = 0,
    queue_max_ms: u32 = 0,
    skipped: u32 = 0,
    cleared: u32 = 0,
    undecrypted: u32 = 0,
    /// Pacotes com padding no RTP, quadros de silêncio e quadros quase no limite de 16 bits.
    padded: u32 = 0,
    silence_frames: u32 = 0,
    near_full: u32 = 0,
    wake_late_ms: i64 = 0,
    busy_ms: i64 = 0,
};

/// Uma pessoa da call: o decodificador Opus e o stream de áudio dela.
const Source = struct {
    ssrc: u32,
    user: Id = 0,
    dec: *c.OpusDecoder,
    stream: ?*c.SDL_AudioStream = null,
    speaking: bool = false,
    last_ms: i64 = 0,
    last_emit_ms: i64 = 0,
    jitter: voz.Jitter = .{},
    seam: voz.Seam = .{},
    /// Só para o registro de depuração: o pico do último quadro e do último salto avisado.
    peak_prev: i32 = 0,
    jump_ms: i64 = 0,

    /// Entrega áudio ao stream, sem degrau onde ele não continua de onde parou.
    fn put(s: *Source, st: *c.SDL_AudioStream, pcm: []i16) void {
        s.seam.apply(pcm);
        _ = c.SDL_PutAudioStreamData(st, pcm.ptr, @intCast(pcm.len * @sizeOf(i16)));
    }

    fn deinit(s: *Source) void {
        c.opus_decoder_destroy(s.dec);
        if (s.stream) |st| c.SDL_DestroyAudioStream(st);
        s.stream = null;
    }

    fn applyGain(s: *Source, v: *Voice) void {
        const st = s.stream orelse return;
        _ = c.SDL_SetAudioStreamGain(st, if (s.user != 0) v.volumeOf(s.user) else 1);
    }
};

// ---------------------------------------------------------------------------
// DAVE (libdave, C API)
// ---------------------------------------------------------------------------

const Dave = struct {
    session: c.DAVESessionHandle = null,
    encryptor: c.DAVEEncryptorHandle = null,
    version: u16 = 0,
    group: Id,
    me: Id,
    /// Nossa mídia sai cifrada (a chave do grupo atual já está valendo).
    enabled: bool = false,
    pending_version: u16 = 0,
    /// Commit/welcome processado, esperando o "execute" do servidor.
    ready: bool = false,
    users: std.AutoHashMapUnmanaged(Id, void) = .empty,
    ssrc_users: std.AutoHashMapUnmanaged(u32, Id) = .empty,
    decryptors: std.AutoHashMapUnmanaged(u32, c.DAVEDecryptorHandle) = .empty,
    local_ssrc: u32 = 0,

    fn init(group: Id, me: Id, version: u16) ?Dave {
        var d: Dave = .{ .group = group, .me = me, .version = version, .pending_version = version };
        c.daveSetLogSinkCallback(logSink);
        d.session = c.daveSessionCreate(null, "", mlsFailure, null);
        if (d.session == null) return null;
        var idbuf: [24]u8 = undefined;
        const self = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{me}, 0) catch return null;
        c.daveSessionInit(d.session, version, group, self.ptr);
        d.encryptor = c.daveEncryptorCreate();
        if (d.encryptor == null) {
            c.daveSessionDestroy(d.session);
            return null;
        }
        d.users.put(alloc, me, {}) catch {};
        return d;
    }

    fn deinit(d: *Dave) void {
        var it = d.decryptors.valueIterator();
        while (it.next()) |h| if (h.* != null) c.daveDecryptorDestroy(h.*);
        d.decryptors.deinit(alloc);
        if (d.encryptor != null) c.daveEncryptorDestroy(d.encryptor);
        if (d.session != null) c.daveSessionDestroy(d.session);
        d.users.deinit(alloc);
        d.ssrc_users.deinit(alloc);
    }

    /// O libdave escreve cada falha e os pacotes do MLS no stderr, e essa escrita
    /// para a thread de voz se o terminal estiver lento.
    fn logSink(_: c.DAVELoggingSeverity, file: [*c]const u8, line: c_int, message: [*c]const u8) callconv(.c) void {
        // Sem as chaves públicas e os "welcome" inteiros, que só encheriam um arquivo feito para ser compartilhado.
        if (debugOn()) {
            const text = std.mem.span(message);
            std.log.info("[dave] {s}:{d} {s}", .{ std.mem.span(file), line, text[0..@min(text.len, 80)] });
        }
    }

    fn mlsFailure(source: [*c]const u8, reason: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        std.log.warn("DAVE: {s} {s}", .{ std.mem.span(source), std.mem.span(reason) });
    }

    fn addUser(d: *Dave, user: Id) void {
        d.users.put(alloc, user, {}) catch {};
    }

    fn removeUser(d: *Dave, user: Id) void {
        _ = d.users.remove(user);
        var ssrcs: [64]u32 = undefined;
        var n: usize = 0;
        var it = d.ssrc_users.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* == user and n < ssrcs.len) {
                ssrcs[n] = kv.key_ptr.*;
                n += 1;
            }
        }
        for (ssrcs[0..n]) |ssrc| {
            _ = d.ssrc_users.remove(ssrc);
            if (d.decryptors.fetchRemove(ssrc)) |x| if (x.value != null) c.daveDecryptorDestroy(x.value);
        }
    }

    fn setSsrcUser(d: *Dave, ssrc: u32, user: Id) void {
        d.ssrc_users.put(alloc, ssrc, user) catch {};
        d.ensureDecryptor(ssrc, user);
    }

    fn keyPackage(d: *Dave, out: []u8) usize {
        var p: [*c]u8 = null;
        var n: usize = 0;
        c.daveSessionGetMarshalledKeyPackage(d.session, &p, &n);
        if (p == null or n == 0) return 0;
        defer c.daveFree(p);
        if (n > out.len) return 0;
        @memcpy(out[0..n], p[0..n]);
        return n;
    }

    /// Recomeça o MLS do zero (grupo novo, commit inválido, fomos movidos).
    fn reinit(d: *Dave, version: u16, group: Id) void {
        d.version = version;
        d.pending_version = version;
        d.group = group;
        d.ready = false;
        var idbuf: [24]u8 = undefined;
        const self = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{d.me}, 0) catch return;
        c.daveSessionReset(d.session);
        c.daveSessionInit(d.session, version, group, self.ptr);
        d.users.put(alloc, d.me, {}) catch {};
    }

    fn setExternalSender(d: *Dave, data: []const u8) void {
        c.daveSessionSetExternalSender(d.session, data.ptr, data.len);
    }

    /// IDs de quem o gateway disse que está na call (o MLS recusa os outros).
    fn recognized(d: *Dave, ids: *[64][24]u8, ptrs: *[64][*c]const u8) usize {
        var n: usize = 0;
        var it = d.users.keyIterator();
        while (it.next()) |u| {
            if (n == ids.len) break;
            const s = std.fmt.bufPrintSentinel(&ids[n], "{d}", .{u.*}, 0) catch continue;
            ptrs[n] = s.ptr;
            n += 1;
        }
        return n;
    }

    fn proposals(d: *Dave, data: []const u8, out: *std.ArrayList(u8)) void {
        var ids: [64][24]u8 = undefined;
        var ptrs: [64][*c]const u8 = undefined;
        const n = d.recognized(&ids, &ptrs);
        var p: [*c]u8 = null;
        var len: usize = 0;
        c.daveSessionProcessProposals(d.session, data.ptr, data.len, &ptrs, n, &p, &len);
        if (p != null) {
            defer c.daveFree(p);
            if (len > 0) out.appendSlice(alloc, p[0..len]) catch {};
        }
    }

    /// null = o servidor reenviou o nosso próprio commit (ignorado).
    fn commit(d: *Dave, tid: u16, data: []const u8) ?bool {
        const res = c.daveSessionProcessCommit(d.session, data.ptr, data.len);
        if (res == null) return false;
        defer c.daveCommitResultDestroy(res);
        if (c.daveCommitResultIsIgnored(res)) return null;
        if (c.daveCommitResultIsFailed(res)) return false;
        d.ready = true;
        d.applyReceiveKeys();
        if (tid == 0) d.executeTransition();
        return true;
    }

    fn welcome(d: *Dave, tid: u16, data: []const u8) ?bool {
        var ids: [64][24]u8 = undefined;
        var ptrs: [64][*c]const u8 = undefined;
        const n = d.recognized(&ids, &ptrs);
        const res = c.daveSessionProcessWelcome(d.session, data.ptr, data.len, &ptrs, n);
        if (res == null) return false;
        c.daveWelcomeResultDestroy(res);
        d.ready = true;
        d.applyReceiveKeys();
        if (tid == 0) d.executeTransition();
        return true;
    }

    fn prepareTransition(d: *Dave, version: u16) void {
        d.pending_version = version;
        // Indo para sem E2EE: já aceita mídia em claro de quem mudou antes.
        if (version == 0) {
            var it = d.decryptors.valueIterator();
            while (it.next()) |h| if (h.* != null) c.daveDecryptorTransitionToPassthroughMode(h.*, true);
        }
    }

    /// As chaves novas valem para ouvir assim que o grupo muda: quem recebe o
    /// "execute" antes de nós já está cifrando com elas. As velhas continuam
    /// aceitas por 10 s, para quem ainda não mudou.
    fn applyReceiveKeys(d: *Dave) void {
        var it = d.ssrc_users.iterator();
        while (it.next()) |kv| d.setRatchet(kv.key_ptr.*, kv.value_ptr.*);
    }

    /// O servidor mandou executar (op 22) ou a transição era a 0: só o que
    /// mandamos muda de chave aqui.
    fn executeTransition(d: *Dave) void {
        d.version = d.pending_version;
        if (d.version == 0) {
            d.enabled = false;
            d.ready = false;
            return;
        }
        if (!d.ready) return;
        d.ready = false;
        var idbuf: [24]u8 = undefined;
        const self = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{d.me}, 0) catch return;
        const self_ratchet = c.daveSessionGetKeyRatchet(d.session, self.ptr);
        if (self_ratchet != null) {
            c.daveEncryptorSetKeyRatchet(d.encryptor, self_ratchet);
            c.daveEncryptorAssignSsrcToCodec(d.encryptor, d.local_ssrc, c.DAVE_CODEC_OPUS);
            c.daveKeyRatchetDestroy(self_ratchet);
        }
        d.enabled = c.daveEncryptorHasKeyRatchet(d.encryptor);
    }

    fn ensureDecryptor(d: *Dave, ssrc: u32, user: Id) void {
        if (d.decryptors.get(ssrc) == null) {
            const dec = c.daveDecryptorCreate();
            if (dec == null) return;
            d.decryptors.put(alloc, ssrc, dec) catch {
                c.daveDecryptorDestroy(dec);
                return;
            };
        }
        d.setRatchet(ssrc, user);
    }

    fn setRatchet(d: *Dave, ssrc: u32, user: Id) void {
        const dec = d.decryptors.get(ssrc) orelse return;
        var idbuf: [24]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&idbuf, "{d}", .{user}, 0) catch return;
        const r = c.daveSessionGetKeyRatchet(d.session, s.ptr);
        if (r == null) return;
        c.daveDecryptorTransitionToKeyRatchet(dec, r);
        c.daveKeyRatchetDestroy(r);
    }

    fn encrypt(d: *Dave, ssrc: u32, frame: []const u8, out: []u8) usize {
        const cap = c.daveEncryptorGetMaxCiphertextByteSize(d.encryptor, c.DAVE_MEDIA_TYPE_AUDIO, frame.len);
        if (cap > out.len) return 0;
        var written: usize = 0;
        const rc = c.daveEncryptorEncrypt(d.encryptor, c.DAVE_MEDIA_TYPE_AUDIO, ssrc, frame.ptr, frame.len, out.ptr, out.len, &written);
        if (rc != c.DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS) return 0;
        return written;
    }

    fn decrypt(d: *Dave, media: c.DAVEMediaType, ssrc: u32, user: Id, frame: []const u8, out: []u8) ?usize {
        // O decryptor aparece quando o SSRC é anunciado (op 5/op 12); se a
        // mídia chegou antes e já sabemos de quem é, cria agora.
        if (d.decryptors.get(ssrc) == null) {
            const owner = d.ssrc_users.get(ssrc) orelse user;
            if (owner == 0) return null;
            d.setSsrcUser(ssrc, owner);
        }
        const dec = d.decryptors.get(ssrc) orelse return null;
        const cap = c.daveDecryptorGetMaxPlaintextByteSize(dec, media, frame.len);
        if (cap > out.len) return null;
        var written: usize = 0;
        const rc = c.daveDecryptorDecrypt(dec, media, frame.ptr, frame.len, out.ptr, out.len, &written);
        if (rc != c.DAVE_DECRYPTOR_RESULT_CODE_SUCCESS) return null;
        return written;
    }

    fn setLocalSsrc(d: *Dave, ssrc: u32) void {
        d.local_ssrc = ssrc;
        if (d.encryptor != null) c.daveEncryptorAssignSsrcToCodec(d.encryptor, ssrc, c.DAVE_CODEC_OPUS);
    }
};
