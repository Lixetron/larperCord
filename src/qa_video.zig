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
fn noMemberHandle(_: *App) bool {
    return qa.find("resize:members") == null and qa.find("resize:call-chat") == null;
}
fn chatOn(app: *App) bool {
    return app.st.call_chat and qa.find("stream-grid") != null and qa.find("stream-chat") != null and qa.find("resize:call-chat") != null;
}
/// O grid e o chat se encostam, e o cabeçalho da conversa (busca, membros) não
/// fica atrás do vão: nada de clicar no que está no outro nó.
fn noSeam(_: *App) bool {
    const g = qa.find("stream-grid") orelse return false;
    const ch = qa.find("stream-chat") orelse return false;
    return ch.x - g.right() <= 1 and qa.find("header-members") == null and qa.find("header-find") == null;
}
fn chatLoaded(app: *App) bool {
    const cs = app.store.channel(call) orelse return false;
    return app.st.call_chat and cs.history == .loaded and qa.find("stream-chat") != null;
}
fn chatOff(app: *App) bool {
    return !app.st.call_chat and qa.find("stream-chat") == null and qa.find("stream-grid") != null;
}
fn chatWider(app: *App) bool {
    return app.st.call_chat_w > 0 and qa.find("resize:call-chat") != null;
}
fn chatDefault(app: *App) bool {
    return app.st.call_chat_w == 0 and qa.find("resize:call-chat") != null;
}
fn callControls(_: *App) bool {
    return qa.find("call-mic") != null and qa.find("call-deafen") != null and qa.find("call-hangup") != null;
}
fn micMuted(app: *App) bool {
    return app.st.muted;
}
fn micLive(app: *App) bool {
    return !app.st.muted;
}
fn deafOn(app: *App) bool {
    return app.st.deafened;
}
fn deafOff(app: *App) bool {
    return !app.st.deafened;
}
fn micMenuOpen(app: *App) bool {
    return app.st.popup == .devices;
}
fn outMenuOpen(app: *App) bool {
    return switch (app.st.popup) {
        .devices => |dv| dv.which == .out,
        else => false,
    };
}
fn menuClosed(app: *App) bool {
    return app.st.popup == .none;
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
    expect("na grade sem o chat, a alça da lista de membros não aparece", noMemberHandle),
    click("stream-chat-toggle"),
    expect("o chat do canal de voz abre ao lado da grade", chatOn),
    expect("grid e chat se encostam, sem a faixa do cabeçalho atrás", noSeam),
    expectLong("o histórico do canal de voz carrega no painel", chatLoaded),
    .{ .wait = 300 },
    shot("video-chat"),
    .{ .drag_by = .{ .from = .{ .mark = "resize:call-chat" }, .dx = -40 } },
    expect("arrastar a alça alarga o chat do canal de voz", chatWider),
    .{ .dclick = .{ .mark = "resize:call-chat" } },
    expect("duplo clique devolve a largura do chat ao padrão", chatDefault),
    click("stream-chat-close"),
    expect("fechar o chat devolve a grade inteira", chatOff),
    expect("a barra da call mostra microfone, áudio e desconectar", callControls),
    click("call-mic-menu"),
    expect("a setinha do microfone abre o menu de dispositivos", micMenuOpen),
    .{ .wait = 300 },
    shot("video-dispositivos"),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("Esc fecha o menu de dispositivos", menuClosed),
    click("call-deafen-menu"),
    expect("a setinha do fone abre a escolha de saída", outMenuOpen),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("Esc fecha a escolha de saída", menuClosed),
    click("call-mic"),
    expect("o microfone da barra silencia", micMuted),
    click("call-mic"),
    expect("o mesmo botão volta a ligar o microfone", micLive),
    click("call-deafen"),
    expect("o botão de áudio ensurdece", deafOn),
    .{ .wait = 250 },
    shot("video-controles"),
    click("call-deafen"),
    expect("o mesmo botão volta a ouvir", deafOff),
    click("call-mic"),
    expect("a barra deixa o microfone ligado de novo", micLive),
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

    s("vídeo: Go Live"),
    run(goLiveOn),
    run(backToChat),
    run(backToCall),
    run(watch),
    expect("a janela abre para o Go Live", viewerOpen),
    click("stream-close"),
    expect("fechar o Go Live", closed),
    .{ .wait = 200 },
    shot("video-depois"),
    click("call-hangup"),
    expect("o botão vermelho encerra a call", notInCall),
};
