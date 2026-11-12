//! A janela do vídeo da call: a grade com todos os participantes (vídeo de
//! quem transmite, avatar de quem não transmite) e o modo foco, com um stream
//! só em tamanho grande.
//!
//! Os quadros chegam decodificados de net/voz_video.zig; aqui só se sobe cada
//! um para a sua textura do SDL e se desenha. Enquanto não chega quadro (ou se
//! o FFmpeg não abriu o H.264) a janela explica o que está acontecendo, em vez
//! de ficar preta sem motivo.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const w = @import("widgets.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const types = @import("../core/types.zig");
const voz_video = @import("../net/voz_video.zig");

const Id = types.Id;

/// Uma textura por stream assistido (a grade tem até quatro).
const Tex = struct { ssrc: u32 = 0, tex: ?*c.SDL_Texture = null, gen: u32 = 0, w: u32 = 0, h: u32 = 0 };
var texs: [voz_video.max_watch]Tex = @splat(.{});
/// A textura recebeu um quadro: o desenho é o mesmo, mas a imagem mudou. Sem
/// isto o `Gate` acha que nada mudou e não manda o quadro para a tela (o vídeo
/// fica em slideshow mesmo decodificando a 60 fps).
var frame_changed = false;

pub fn takeChanged() bool {
    defer frame_changed = false;
    return frame_changed;
}

var info_ms: i64 = 0;
var info_frames: u64 = 0;
var info_fps: f32 = 0;
var shown_fps: f32 = 0;
var shown_base: u64 = 0;
var bytes_base: u64 = 0;
var unique_base: u64 = 0;
var mbps: f32 = 0;
var unique_fps: f32 = 0;

fn dropTex(t: *Tex) void {
    if (t.tex) |x| c.SDL_DestroyTexture(x);
    t.* = .{};
}

fn dropAll() void {
    for (&texs) |*t| dropTex(t);
}

fn texFor(ssrc: u32) *Tex {
    for (&texs) |*t| if (t.ssrc == ssrc) return t;
    for (&texs) |*t| {
        if (t.ssrc != 0) continue;
        t.ssrc = ssrc;
        return t;
    }
    dropTex(&texs[0]);
    texs[0].ssrc = ssrc;
    return &texs[0];
}

/// Sobe o quadro daquele stream, se houver um novo. Devolve as dimensões.
fn updateTexture(ctx: *d.Ctx, ssrc: u32) ?[2]u32 {
    const view = voz_video.lockFrameOf(ssrc) orelse return null;
    defer voz_video.unlockFrame();
    const t = texFor(ssrc);
    if (t.tex == null or t.w != view.w or t.h != view.h) {
        dropTex(t);
        t.ssrc = ssrc;
        t.tex = c.SDL_CreateTexture(ctx.images.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, @intCast(view.w), @intCast(view.h));
        if (t.tex) |x| _ = c.SDL_SetTextureScaleMode(x, c.SDL_SCALEMODE_LINEAR);
        t.w = view.w;
        t.h = view.h;
    }
    const x = t.tex orelse return null;
    if (view.gen != t.gen) {
        _ = c.SDL_UpdateTexture(x, null, view.px.ptr, @intCast(view.w * 4));
        t.gen = view.gen;
        voz_video.noteShown();
        frame_changed = true;
    }
    return .{ view.w, view.h };
}

/// Colunas da grade: 1, 2, 2, 3, 3… como no cliente oficial.
fn colsFor(n: usize) usize {
    return switch (n) {
        0, 1 => 1,
        2, 3, 4 => 2,
        5, 6 => 3,
        else => 4,
    };
}

pub fn overlay(ctx: *d.Ctx) void {
    if (!ctx.st.stream_open or ctx.st.watching == 0) {
        // A grade embutida usa as texturas: só descarta quando ninguém as usa.
        if (!ctx.st.call_view) dropAll();
        return;
    }
    // 60 qps no máximo: o stream pode ser 60 fps e a janela acompanha.
    anim.at(ctx.now_ms + 16);
    single(ctx);
}

/// Participantes da call: quem está no canal de voz (nós incluídos) e, numa
/// DM/grupo, o dono da chamada.
fn members(ctx: *d.Ctx, out: *[voz_video.max_streams]Id) usize {
    var n: usize = 0;
    if (ctx.st.voice) |ch| {
        if (ctx.store.channel(ch)) |cs| {
            for (cs.voice_members.items) |uid| {
                if (n == out.len) break;
                out[n] = uid;
                n += 1;
            }
        }
    }
    if (n == 0 and ctx.st.watching != 0) {
        out[0] = ctx.st.watching;
        n = 1;
    }
    if (n == 0) {
        out[0] = ctx.store.me;
        n = 1;
    }
    return n;
}

fn grid(ctx: *d.Ctx) void {
    const win = ctx.win;
    const full = ctx.st.stream_fullscreen;
    const cw: f32 = if (full) win.w else @min(win.w - 64, 1180);
    const ch: f32 = if (full) win.h else @min(win.h - 64, cw * 0.62 + 44);
    const card: d.Rect = .{
        .x = win.x + (win.w - cw) / 2,
        .y = win.y + (win.h - ch) / 2,
        .w = cw,
        .h = ch,
    };

    c.ImGui_SetNextWindowPos(d.v(win.x, win.y), 0);
    c.ImGui_SetNextWindowSize(d.v(win.w, win.h), 0);
    c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin("##stream", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    defer c.ImGui_End();
    const dl = c.ImGui_GetWindowDrawList();
    const k: f32 = 1;
    if (!full) d.rect(dl, win, d.Rgba.black.alpha(0.55 * k), 0);
    const radius: f32 = if (full) 0 else @max(ctx.th.radius + 4, 6);
    d.shadow(dl, card, radius, 24, ctx.col(.shadow).alpha(k));
    d.rect(dl, card, ctx.col(.overlay), radius);
    qa.mark(card, "stream-grid", .{});

    const head_h: f32 = 36;
    const fam = ctx.ui;
    const tf = fam.get(.semibold);
    _ = d.textClipped(dl, tf, 14, card.x + 12, card.y + (head_h - 14) / 2, ctx.col(.text), i18n.tr("chamada", "call"), card.w - 110);

    const close_r: d.Rect = .{ .x = card.right() - 34, .y = card.y + 8, .w = 20, .h = 20 };
    const full_r: d.Rect = .{ .x = card.right() - 62, .y = card.y + 8, .w = 20, .h = 20 };
    qa.mark(close_r, "stream-close", .{});
    qa.mark(full_r, "stream-fullscreen", .{});
    const hc = d.hit(ctx, 1, close_r);
    const hf = d.hit(ctx, 2, full_r);
    if (hc.hovered) d.rect(dl, close_r, ctx.col(.hover), 4);
    if (hf.hovered) d.rect(dl, full_r, ctx.col(.hover), 4);
    const ink = ctx.col(.muted);
    d.line(dl, close_r.x + 6, close_r.y + 6, close_r.right() - 6, close_r.bottom() - 6, ink, 1.6);
    d.line(dl, close_r.right() - 6, close_r.y + 6, close_r.x + 6, close_r.bottom() - 6, ink, 1.6);
    d.border(dl, .{ .x = full_r.x + 5, .y = full_r.y + 5, .w = 10, .h = 10 }, ink, 1, 1.4);
    if (hc.clicked) ctx.act(.{ .watch_stream = 0 });
    if (hf.clicked) ctx.st.stream_fullscreen = !full;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and !c.ImGui_IsAnyItemActive()) ctx.act(.{ .watch_stream = 0 });

    const area: d.Rect = .{
        .x = card.x + 4,
        .y = card.y + head_h,
        .w = card.w - 8,
        .h = card.h - head_h - @as(f32, if (full) 4 else 8),
    };
    d.rect(dl, area, d.Rgba.black.alpha(k), if (full) 0 else 4);

    drawTiles(ctx, area);
}

/// A grade em si: quem está na call, o vídeo de quem transmite e o avatar dos
/// demais. Serve tanto para a janela quanto para a área embutida no chat.
fn drawTiles(ctx: *d.Ctx, area: d.Rect) void {
    const dl = c.ImGui_GetWindowDrawList();
    const fam = ctx.ui;
    const k: f32 = 1;
    // Quem está na call.
    var ids: [voz_video.max_streams]Id = undefined;
    const n = members(ctx, &ids);
    const cols = colsFor(n);
    const rows = (n + cols - 1) / cols;
    const gap: f32 = 6;
    const tw = (@max(area.w, 40) - gap * @as(f32, @floatFromInt(cols -| 1))) / @as(f32, @floatFromInt(cols));
    const th = (@max(area.h, 40) - gap * @as(f32, @floatFromInt(rows -| 1))) / @as(f32, @floatFromInt(rows));

    // A lista do que assistir: todos os que transmitem, no tamanho do tile.
    var reqs: [voz_video.max_watch]voz_video.WatchReq = undefined;
    var n_req: usize = 0;
    for (ids[0..n]) |uid| {
        if (n_req == voz_video.max_watch) break;
        const ssrc = voz_video.ssrcOf(uid);
        if (ssrc == 0) continue;
        reqs[n_req] = .{
            .user = uid,
            .src = if (ctx.store.voiceFlags(uid).stream) .stream else .voice,
            .ssrc = ssrc,
            .w = @intFromFloat(@max(tw - 8, 16)),
            .h = @intFromFloat(@max(th - 8, 16)),
        };
        n_req += 1;
    }
    voz_video.setWatches(reqs[0..n_req]);

    for (ids[0..n], 0..) |uid, i| {
        const cx = @as(usize, i % cols);
        const cy = @as(usize, i / cols);
        const tile: d.Rect = .{
            .x = area.x + @as(f32, @floatFromInt(cx)) * (tw + gap),
            .y = area.y + @as(f32, @floatFromInt(cy)) * (th + gap),
            .w = tw,
            .h = th,
        };
        qa.mark(tile, "stream-tile:{d}", .{i});
        d.rect(dl, tile, ctx.col(.bg).mix(ctx.col(.rail), 0.5), 4);
        const ssrc = voz_video.ssrcOf(uid);
        var painted = false;
        if (ssrc != 0) {
            if (updateTexture(ctx, ssrc)) |sz| {
                const vw: f32 = @floatFromInt(sz[0]);
                const vh: f32 = @floatFromInt(sz[1]);
                const s = @min((tile.w - 8) / vw, (tile.h - 8) / vh);
                const iw = vw * s;
                const ih = vh * s;
                const ir: d.Rect = .{ .x = tile.x + (tile.w - iw) / 2, .y = tile.y + (tile.h - ih) / 2, .w = iw, .h = ih };
                const ref: c.ImTextureRef = .{ ._TexData = null, ._TexID = @intFromPtr(texFor(ssrc).tex.?) };
                c.ImDrawList_AddImageRounded(dl, ref, d.v(ir.x, ir.y), d.v(ir.right(), ir.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(k), 4, 0);
                painted = true;
            }
        }
        if (!painted) {
            // Sem vídeo: o avatar, como na grade do Discord.
            const rad = @min(tile.w, tile.h) * 0.22;
            w.avatar(ctx, dl, tile.x + tile.w / 2, tile.y + tile.h / 2 - 4, rad, uid, .circle, ctx.col(.rail), 1);
        }
        // Faixa com o nome.
        const user = ctx.store.user(uid);
        if (user) |u| {
            var nb: [96]u8 = undefined;
            const name = std.fmt.bufPrint(&nb, "{s}", .{d.utf8Prefix(u.name, 40)}) catch "";
            const nf = fam.get(.medium);
            const nw = d.width(nf, 11, name) + 12;
            const nr: d.Rect = .{ .x = tile.x + 6, .y = tile.bottom() - 22, .w = @min(nw, tile.w - 12), .h = 16 };
            d.rect(dl, nr, d.Rgba.black.alpha(0.55 * k), 3);
            _ = d.textClipped(dl, nf, 11, nr.x + 6, nr.y + 3, ctx.col(.text), name, nr.w - 10);
        }
        // Quem está falando ganha o anel verde (some sozinho quando para).
        if (ctx.store.isSpeaking(uid, ctx.now_ms)) {
            d.border(dl, tile, d.Rgba.hex(0x23a55a), 4, 2);
        }
        const hr = d.hit(ctx, @as(usize, 10 + i), tile);
        const f = ctx.store.voiceFlags(uid);
        // O SSRC pode ainda não existir (a conexão do Go Live nasce ao clicar):
        // o clique vale mesmo assim.
        if (hr.clicked and (ssrc != 0 or f.stream or f.camera)) ctx.act(.{ .watch_stream = uid });
        if (hr.hovered and (ssrc != 0 or f.stream or f.camera)) d.border(dl, tile, ctx.col(.accent).alpha(0.7 * k), 4, 1.4);
    }
}

/// A grade embutida no lugar do chat e da lista de membros: é o que se vê ao
/// entrar num canal de voz, como no cliente oficial.
pub fn embedded(ctx: *d.Ctx, area: d.Rect) void {
    qa.mark(area, "stream-grid", .{});
    d.rect(ctx.dl, area, ctx.col(.bg), 0);
    drawTiles(ctx, area.inset(8, 8));
}

fn single(ctx: *d.Ctx) void {
    const win = ctx.win;
    const full = ctx.st.stream_fullscreen;
    const cw: f32 = if (full) win.w else @min(win.w - 64, 1040);
    const ch: f32 = if (full) win.h else @min(win.h - 64, cw * 9 / 16 + 44);
    const card: d.Rect = .{
        .x = win.x + (win.w - cw) / 2,
        .y = win.y + (win.h - ch) / 2,
        .w = cw,
        .h = ch,
    };

    c.ImGui_SetNextWindowPos(d.v(win.x, win.y), 0);
    c.ImGui_SetNextWindowSize(d.v(win.w, win.h), 0);
    c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin("##stream", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse);
    defer c.ImGui_End();
    const dl = c.ImGui_GetWindowDrawList();

    if (!full) d.rect(dl, win, d.Rgba.black.alpha(0.55), 0);
    const radius: f32 = if (full) 0 else @max(ctx.th.radius + 4, 6);
    d.shadow(dl, card, radius, 24, ctx.col(.shadow));
    d.rect(dl, card, ctx.col(.overlay), radius);
    qa.mark(card, "stream-viewer", .{});

    const head_h: f32 = 36;
    const fam = ctx.ui;
    const user = ctx.store.user(ctx.st.watching);
    var buf: [160]u8 = undefined;
    const title = if (user) |u|
        i18n.fmt(&buf, "assistindo {s}", "watching {s}", .{u.name})
    else
        i18n.tr("assistindo", "watching");
    _ = d.textClipped(dl, fam.get(.semibold), 14, card.x + 12, card.y + (head_h - 14) / 2, ctx.col(.text), title, card.w - 140);

    const close_r: d.Rect = .{ .x = card.right() - 34, .y = card.y + 8, .w = 20, .h = 20 };
    const full_r: d.Rect = .{ .x = card.right() - 62, .y = card.y + 8, .w = 20, .h = 20 };
    const grid_r: d.Rect = .{ .x = card.right() - 90, .y = card.y + 8, .w = 20, .h = 20 };
    qa.mark(close_r, "stream-close", .{});
    qa.mark(full_r, "stream-fullscreen", .{});
    qa.mark(grid_r, "stream-grid-button", .{});
    const hc = d.hit(ctx, 1, close_r);
    const hf = d.hit(ctx, 2, full_r);
    const hg = d.hit(ctx, 3, grid_r);
    if (hc.hovered) d.rect(dl, close_r, ctx.col(.hover), 4);
    if (hf.hovered) d.rect(dl, full_r, ctx.col(.hover), 4);
    if (hg.hovered) d.rect(dl, grid_r, ctx.col(.hover), 4);
    const ink = ctx.col(.muted);
    d.line(dl, close_r.x + 6, close_r.y + 6, close_r.right() - 6, close_r.bottom() - 6, ink, 1.6);
    d.line(dl, close_r.right() - 6, close_r.y + 6, close_r.x + 6, close_r.bottom() - 6, ink, 1.6);
    d.border(dl, .{ .x = full_r.x + 5, .y = full_r.y + 5, .w = 10, .h = 10 }, ink, 1, 1.4);
    // Ícone de grade: quatro quadradinhos.
    var gx: usize = 0;
    while (gx < 2) : (gx += 1) {
        var gy: usize = 0;
        while (gy < 2) : (gy += 1) {
            d.border(dl, .{ .x = grid_r.x + 4 + @as(f32, @floatFromInt(gx)) * 6, .y = grid_r.y + 4 + @as(f32, @floatFromInt(gy)) * 6, .w = 5, .h = 5 }, ink, 0, 1.2);
        }
    }
    if (hc.clicked) ctx.act(.{ .watch_stream = 0 });
    if (hf.clicked) ctx.st.stream_fullscreen = !full;
    if (hg.clicked) ctx.act(.{ .watch_stream = 0 });
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and !c.ImGui_IsAnyItemActive()) ctx.act(.{ .watch_stream = 0 });

    const area: d.Rect = .{
        .x = card.x + 4,
        .y = card.y + head_h,
        .w = card.w - 8,
        .h = card.h - head_h - @as(f32, if (full) 4 else 8),
    };
    qa.mark(area, "stream-video", .{});
    d.rect(dl, area, d.Rgba.black.alpha(1), if (full) 0 else 4);
    const ssrc = voz_video.ssrcOf(ctx.st.watching);
    voz_video.setViewFor(ssrc, @intFromFloat(@max(area.w, 2)), @intFromFloat(@max(area.h, 2)));

    if (ssrc != 0) {
        if (updateTexture(ctx, ssrc)) |sz| {
            const vw: f32 = @floatFromInt(sz[0]);
            const vh: f32 = @floatFromInt(sz[1]);
            const s = @min(area.w / vw, area.h / vh);
            const iw = vw * s;
            const ih = vh * s;
            const ir: d.Rect = .{ .x = area.x + (area.w - iw) / 2, .y = area.y + (area.h - ih) / 2, .w = iw, .h = ih };
            const ref: c.ImTextureRef = .{ ._TexData = null, ._TexID = @intFromPtr(texFor(ssrc).tex.?) };
            c.ImDrawList_AddImageRounded(dl, ref, d.v(ir.x, ir.y), d.v(ir.right(), ir.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(1), if (full) 0 else 4, 0);
            const st = voz_video.stats();
            if (info_ms == 0) {
                info_ms = ctx.now_ms;
                info_frames = st.frames;
                shown_base = st.shown;
                bytes_base = st.bytes;
                unique_base = st.unique;
            } else if (ctx.now_ms - info_ms >= 1000) {
                const dt: f32 = @floatFromInt(ctx.now_ms - info_ms);
                info_fps = @as(f32, @floatFromInt(st.frames - info_frames)) * 1000 / dt;
                shown_fps = @as(f32, @floatFromInt(st.shown - shown_base)) * 1000 / dt;
                unique_fps = @as(f32, @floatFromInt(st.unique - unique_base)) * 1000 / dt;
                mbps = @as(f32, @floatFromInt(st.bytes - bytes_base)) * 8 / dt / 1000;
                info_ms = ctx.now_ms;
                info_frames = st.frames;
                shown_base = st.shown;
                bytes_base = st.bytes;
                unique_base = st.unique;
            }
            var ib: [256]u8 = undefined;
            const src = voz_video.sourceSize();
            const rp = c.SDL_GetRendererName(ctx.images.renderer);
            const rname = if (rp != null) std.mem.span(@as([*:0]const u8, @ptrCast(rp))) else "?";
            const info = std.fmt.bufPrint(&ib, "{d}×{d} → {d}×{d} · {d}/{d} fps · {d} uniq · mov {d} · {d:.1} Mbps · {s}", .{
                src[0], src[1],
                sz[0], sz[1],
                @as(u32, @intFromFloat(std.math.clamp(info_fps, 0, 999))),
                @as(u32, @intFromFloat(std.math.clamp(shown_fps, 0, 999))),
                @as(u32, @intFromFloat(std.math.clamp(unique_fps, 0, 999))),
                st.motion,
                mbps,
                rname,
            }) catch "";
            const inf = fam.get(.medium);
            const iw_info = d.width(inf, 10, info);
            const ir_info: d.Rect = .{ .x = ir.right() - iw_info - 10, .y = ir.bottom() - 16, .w = iw_info + 6, .h = 13 };
            d.rect(dl, ir_info, d.Rgba.black.alpha(0.35), 3);
            d.text(dl, inf, 10, ir_info.x + 3, ir_info.y + 2, ctx.col(.muted), info);
            if (d.hitRaw(ctx, ir).hovered and c.ImGui_IsMouseDoubleClicked(0)) ctx.st.stream_fullscreen = !full;
            return;
        }
    }

    // Sem quadro: diz por quê.
    const st = voz_video.status();
    const f = fam.get(.medium);
    const msg: []const u8 = switch (st) {
        .no_codec => i18n.tr("para ver vídeo aqui falta o FFmpeg", "video here needs FFmpeg"),
        .stalled => i18n.tr("perdemos um quadro; esperando o próximo quadro-chave…", "a frame was lost; waiting for the next keyframe…"),
        else => if (voz_video.sinceFrameMs() > 3000)
            i18n.tr("sem sinal do stream", "no signal from the stream")
        else
            i18n.tr("conectando ao stream…", "connecting to the stream…"),
    };
    const mx = area.x + (area.w - d.width(f, 14, msg)) / 2;
    d.text(dl, f, 14, mx, area.y + area.h / 2 - 7, ctx.col(.muted), msg);
}
