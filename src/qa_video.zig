//! QA do vídeo na call: o selo LIVE, a janela de quem assiste, a tela cheia e
//! o fechamento. Sem FFmpeg e sem Discord: a thread de vídeo desenha um
//! gradiente de teste e o quadro passa pela textura e pela janela de verdade.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const voz_video = @import("net/voz_video.zig");
const ffmpeg = @import("platform/ffmpeg.zig");
const Id = @import("core/types.zig").Id;

const call: Id = 500014;
/// Alguém da call de demonstração (o mesmo que o mixer da bateria de voz usa).
const who: Id = 1001;
const ssrc: u32 = 0x5eed_1001;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn expectLong(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 5000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}

fn inCall(app: *App) bool {
    return app.st.voice == call;
}
fn notInCall(app: *App) bool {
    return app.st.voice == null;
}
fn patternOn(_: *App) void {
    voz_video.setPattern(true);
}
fn prepare(app: *App) void {
    if (app.st.settings.open) app.handle(.close_settings);
    // A lista de canais precisa estar no servidor da demonstração (o selo LIVE
    // é desenhado nela), e a call é a mesma das outras baterias.
    app.handle(.{ .select_guild = 500000 });
    if (app.st.voice != call) app.handle(.{ .toggle_voice = call });
    // A bateria anterior pode ter mexido na lista da call: garante quem transmite.
    app.events.push(.{ .voice_state = .{ .channel = call, .user = who, .flags = .{} } });
    app.events.push(.{ .voice_video = .{ .user = who, .video_ssrc = ssrc, .active = true } });
}
fn watch(app: *App) void {
    app.handle(.{ .watch_stream = who });
}
fn goLiveOn(app: *App) void {
    // A câmera some e a pessoa passa a transmitir pelo Go Live (self_stream).
    app.events.push(.{ .voice_video = .{ .user = who, .video_ssrc = 0, .active = false } });
    app.events.push(.{ .voice_state = .{ .channel = call, .user = who, .flags = .{ .stream = true } } });
}
fn livePill(_: *App) bool {
    return qa.find("voice-live:1001") != null;
}
fn liveOn(_: *App) bool {
    return qa.find("voice-live") != null;
}
fn viewerOpen(app: *App) bool {
    return app.st.stream_open and app.st.watching == who and qa.find("stream-viewer") != null;
}
fn gotFrame(_: *App) bool {
    return voz_video.status() == .playing and voz_video.sinceFrameMs() >= 0 and voz_video.stats().frames > 0;
}
fn fullscreen(app: *App) bool {
    return app.st.stream_fullscreen and qa.find("stream-video") != null;
}
fn closed(app: *App) bool {
    return !app.st.stream_open and qa.find("stream-viewer") == null;
}

fn gridOpen(_: *App) bool {
    return qa.find("stream-grid") != null;
}
fn chatBack(_: *App) bool {
    return qa.find("stream-grid") == null;
}
fn backToChat(app: *App) void {
    app.st.call_view = false;
}
fn backToCall(app: *App) void {
    app.st.call_view = true;
}

/// Decodifica `qa-out/teste.h264` (um quadro Annex-B gerado pelo ffmpeg) com o
/// mesmo caminho do vídeo da call — inclusive o swscale para RGBA. Sem o
/// arquivo, o passo só passa (as baterias normais não têm esse arquivo).
var decode_ok = true;
fn decodeFile(_: *App) void {
    decode_ok = false;
    const api = ffmpeg.get() orelse {
        decode_ok = true; // sem FFmpeg (CI): não é esta bateria
        return;
    };
    var dec = ffmpeg.Raw.open(api, 2) catch return;
    defer dec.close();
    const gpa = std.heap.c_allocator;
    var size: usize = 0;
    const raw = c.SDL_LoadFile("qa-out/teste.h264", &size) orelse {
        decode_ok = true; // não é esta bateria
        return;
    };
    defer c.SDL_free(raw);
    if (size == 0) return;
    const data: []const u8 = @as([*]const u8, @ptrCast(raw))[0..size];
    if (!dec.send(data)) return;
    dec.drain();
    var got_frame = false;
    while (dec.receive() == 0) {
        const sz = dec.size();
        if (sz[0] == 0 or sz[1] == 0) continue;
        const out = gpa.alloc(u8, ffmpeg.rgbaSize(sz[0], sz[1])) catch return;
        defer gpa.free(out);
        if (!dec.toRgba(out, sz[0], sz[1])) return;
        std.debug.print("qa-video: h264 decodificado {d}x{d}, rgba {d},{d},{d}\n", .{ sz[0], sz[1], out[0], out[1], out[2] });
        got_frame = true;
        break;
    }
    if (!got_frame) return;
    decode_ok = true;
}
fn decoded(_: *App) bool {
    return decode_ok;
}

fn leave(app: *App) void {
    app.handle(.leave_voice);
}

pub const ops = [_]Op{
    s("vídeo: decodificador"),
    run(decodeFile),
    expect("o H.264 do FFmpeg decodifica no caminho do vídeo", decoded),
    s("vídeo: selo e janela"),
    run(patternOn),
    run(prepare),
    expect("entrar na call", inCall),
    run(backToChat),
    expect("o selo LIVE aparece para quem transmite", liveOn),
    shot("video-live"),
    run(backToCall),
    run(watch),
    expect("abrir a janela de quem transmite", viewerOpen),
    expectLong("o padrão de teste chega à textura", gotFrame),
    shot("video-janela"),
    click("stream-fullscreen"),
    expect("a tela cheia encaixa o vídeo", fullscreen),
    .{ .wait = 300 },
    shot("video-tela-cheia"),
    click("stream-grid-button"),
    expect("a grade da call mostra os participantes", gridOpen),
    .{ .wait = 300 },
    shot("video-grade"),
    run(backToChat),
    expect("escolher uma conversa volta para o chat", chatBack),
    expect("a call continua depois de fechar o vídeo", inCall),

    s("vídeo: Go Live na faixa de voz"),
    run(goLiveOn),
    run(backToChat),
    expect("o botão LIVE aparece na faixa da call", livePill),
    run(backToCall),
    run(watch),
    expect("a janela abre para o Go Live", viewerOpen),
    click("stream-close"),
    expect("fechar o Go Live", closed),
    .{ .wait = 200 },
    shot("video-depois"),
    run(leave),
    expect("sair da call", notInCall),
};
