function demo_render(varargin)
% DEMO_RENDER  Musical, nonlinear, polyphonic demo phrases for listening.
%
% Renders longer, louder, more representative audio than the single-strike
% study outputs: the NON-LINEAR update (alpha chaos term, as in the RTL), a
% polyphonic phrase (notes overlap-added so decays ring together), a DC/rumble
% high-pass, and full-scale normalisation. Writes model/outputs/demo_*.wav.
%
% Options: 'outdir' (char) [default model/outputs/]

    C.FS = 48000; C.H = 0.01; C.NX = 32; C.NY = 32;
    P.outdir = fullfile(fileparts(mfilename('fullpath')), 'outputs');
    P = parse_opts(P, varargin);
    if ~exist(P.outdir, 'dir'); mkdir(P.outdir); end

    % pentatonic scale as semitone offsets; pitch -> gamma2 = g0 * 2^(semi/6)
    penta = [0 3 5 7 10 12 15];

    % --- gong: long shimmer, strong nonlinearity, free edges ---------------
    voice.g0 = 0.05; voice.gmax = 0.451; voice.alpha = 0.42;
    voice.sigma = 0.4; voice.bc = 'free'; voice.note_dur = 3.0;
    sched = [ 0.0 0; 0.8 4; 1.6 2; 2.4 7; 3.4 0; 3.4 4; 3.4 7 ];  % melody + a chord
    render_phrase('demo_gong', C, voice, penta, sched, 6.5, P.outdir);

    % --- plate: bright, sustained, metallic --------------------------------
    voice.g0 = 0.10; voice.alpha = 0.30; voice.sigma = 2.0; voice.bc = 'free';
    voice.note_dur = 3.0;
    sched = [ 0.0 5; 0.45 3; 0.9 7; 1.35 10; 1.8 3; 2.2 0; 2.2 5; 2.2 10 ];
    render_phrase('demo_plate', C, voice, penta, sched, 5.5, P.outdir);

    % --- drum groove: short, punchy, fixed edges ---------------------------
    voice.g0 = 0.16; voice.alpha = 0.12; voice.sigma = 90.0; voice.bc = 'fixed';
    voice.note_dur = 0.5;
    sched = [ 0.0 0; 0.5 0; 0.9 5; 1.2 0; 1.7 0; 2.1 5; 2.4 7; 2.7 0 ];
    render_phrase('demo_drum', C, voice, penta, sched, 3.6, P.outdir);
end

% ===========================================================================
function render_phrase(name, C, v, scale, sched, total_s, outdir)
    fs = C.FS;
    Ntot = round(total_s * fs);
    L = zeros(Ntot, 1); R = zeros(Ntot, 1);

    % cache one rendered note per distinct pitch index
    cache = containers.Map('KeyType', 'double', 'ValueType', 'any');
    taps = [round(C.NY/2)-5, round(C.NX/2)-6, round(C.NY/2)+6, round(C.NX/2)+5];
    if strcmp(v.bc, 'free'); taps = [6 6 C.NY-5 C.NX-5]; end

    for s = 1:size(sched, 1)
        t0  = sched(s, 1); step_i = sched(s, 2);
        semi = scale(mod(step_i, numel(scale)) + 1) + 12*floor(step_i/numel(scale));
        key = semi;
        if ~isKey(cache, key)
            g2 = min(v.g0 * 2^(semi/6), v.gmax * 0.98);   % octave = gamma2 x4
            cache(key) = render_note(C, g2, v, taps);
        end
        note = cache(key);
        onset = round(t0 * fs);
        len = min(size(note,1), Ntot - onset);
        if len <= 0; continue; end
        L(onset+1:onset+len) = L(onset+1:onset+len) + note(1:len,1);
        R(onset+1:onset+len) = R(onset+1:onset+len) + note(1:len,2);
    end

    L = norm_hpf(L, fs);  R = norm_hpf(R, fs);
    % loudness-normalise to a target RMS, then a soft limiter (tanh) so every
    % voice is comparably loud regardless of how transient/sparse it is
    target = 0.16;
    r = sqrt(mean([L;R].^2));
    if r > 0; L = L*(target/r); R = R*(target/r); end
    L = tanh(1.3*L); R = tanh(1.3*R);
    g = 0.95 / max(max(abs([L;R])), eps);
    audiowrite(fullfile(outdir, [name '.wav']), [L*g R*g], fs);
    printf('%s.wav  %.1f s  (%d notes)\n', name, total_s, size(sched,1));
end

% one struck note, NON-LINEAR update, stereo pickups
function note = render_note(C, gamma2, v, taps)
    fs = C.FS; k = 1/fs;
    a0 = 1/(1 + v.sigma*k); sigk1 = 1 - v.sigma*k;
    U = zeros(C.NY, C.NX); U1 = U;
    % Gaussian centre strike
    [jj, ii] = meshgrid(0:C.NX-1, 0:C.NY-1);
    d2 = (ii-(C.NY-1)/2).^2 + (jj-(C.NX-1)/2).^2;
    U = exp(-d2 ./ (2*1.6^2));
    n = round(v.note_dur * fs);
    note = zeros(n, 2);
    Lk = [0 1 0;1 -4 1;0 1 0];
    for t = 1:n
        gl = min(max(gamma2 + v.alpha.*U.^2, 0), v.gmax);   % local nonlinear gamma2
        if strcmp(v.bc, 'fixed')
            lap = conv2(U, Lk, 'same');
        else
            UP = padarray_reflect(U);
            lap = UP(3:end,2:end-1)+UP(1:end-2,2:end-1)+UP(2:end-1,3:end)+UP(2:end-1,1:end-2)-4*U;
        end
        Un = a0 .* (2*U - sigk1.*U1 + gl.*lap);
        U1 = U; U = Un;
        note(t,1) = U(taps(1),taps(2));
        note(t,2) = U(taps(3),taps(4));
    end
end

% ===========================================================================
function y = norm_hpf(x, fs)
    % one-pole DC/rumble high-pass (~45 Hz) so the audible band gets the
    % headroom instead of an inaudible DC excursion
    fc = 45; a = exp(-2*pi*fc/fs);
    y = zeros(size(x)); xp = 0; yp = 0;
    for n = 1:numel(x)
        y(n) = a*(yp + x(n) - xp);
        xp = x(n); yp = y(n);
    end
end

function UP = padarray_reflect(U)
    [ny,nx] = size(U);
    UP = zeros(ny+2, nx+2);
    UP(2:ny+1,2:nx+1) = U;
    UP(1,2:nx+1)=U(2,:); UP(ny+2,2:nx+1)=U(ny-1,:);
    UP(2:ny+1,1)=U(:,2); UP(2:ny+1,nx+2)=U(:,nx-1);
end

function P = parse_opts(P, args)
    for i = 1:2:numel(args)
        switch lower(args{i}); case 'outdir'; P.outdir = args{i+1}; end
    end
end
