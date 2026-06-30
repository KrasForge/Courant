function fdtd_ref(varargin)
% FDTD_REF  2D lossy wave-equation FDTD reference model (MATLAB / Octave).
%
% Drives the Mesh2D solver (see Mesh2D.m) for the explicit centred-difference
% update of README §1, renders a stereo .wav impulse response and a
% displacement animation for sanity checking.
%
% Name/value options (all optional):
%   'free'     (logical) use free (Neumann) boundaries  [default false → fixed]
%   'duration' (s)       simulation duration            [default 2.0]
%   'sigma'    (1/s)     damping coefficient            [default 1.5]
%   'c'        (m/s)     wave speed                      [default 144]
%   'outdir'   (char)    output directory               [default model/outputs/]
%
% Outputs:
%   <outdir>/impulse_<bc>.wav        stereo 16-bit PCM audio
%   <outdir>/displacement_<bc>.gif   false-colour displacement animation
%
% Examples:
%   fdtd_ref                       % fixed-boundary impulse response
%   fdtd_ref('free', true)         % free-boundary variant
%   fdtd_ref('duration', 3)        % longer tail
%   fdtd_ref('sigma', 0.5)         % slower decay

    % ---- Documented default parameters (reproducible reference run) -------
    P.nx       = 32;        % grid width  (columns)
    P.ny       = 32;        % grid height (rows)
    P.fs       = 48000;     % audio sample rate (Hz)
    P.h        = 0.01;      % spatial step (m)
    % c=144 m/s -> gamma=0.300, gamma^2=0.090 (well inside the 0.5 CFL limit)
    % Fundamental mode (1,1) on a 32x32 fixed-BC grid: ~318 Hz.
    P.c        = 144.0;
    P.sigma    = 1.5;       % damping (1/s); energy e-fold time ~0.67 s
    P.duration = 2.0;       % simulation duration (s)
    P.free     = false;     % boundary: false -> 'fixed', true -> 'free'

    here = fileparts(mfilename('fullpath'));
    P.outdir = fullfile(here, 'outputs');

    P = parse_opts(P, varargin);
    bc = bc_name(P.free);

    k = 1.0 / P.fs;
    gamma = P.c * k / P.h;
    fprintf('Parameters:\n');
    fprintf('  grid      : %d x %d\n', P.nx, P.ny);
    fprintf('  fs        : %g Hz,  k = %.2e s\n', P.fs, k);
    fprintf('  h         : %g m\n', P.h);
    fprintf('  c         : %g m/s\n', P.c);
    fprintf('  gamma     : %.4f  (gamma^2 = %.4f, CFL limit = 0.5000)\n', ...
            gamma, gamma^2);
    fprintf('  sigma     : %g 1/s\n', P.sigma);
    fprintf('  boundary  : %s\n', bc);
    fprintf('  duration  : %g s  (%d samples)\n\n', ...
            P.duration, round(P.duration * P.fs));

    % ---- Build mesh and excite it -----------------------------------------
    mesh = Mesh2D(P.nx, P.ny, P.fs, P.h, P.c, P.sigma, bc);

    si = floor(P.ny / 2);   % strike centre (0-indexed coords for the Gaussian)
    sj = floor(P.nx / 2);
    mesh.strike(si, sj, 2.0, 1.0);

    % Stereo pickup taps (1-based MATLAB indices). Equivalent to the Python
    % reference nodes (ny/2, nx/4) and (ny/2, 3*nx/4) in 0-indexed form.
    pickup = [floor(P.ny/2) + 1, floor(P.nx/4)   + 1;    % left  channel
              floor(P.ny/2) + 1, floor(3*P.nx/4) + 1];   % right channel
    fprintf('Strike    : (%d, %d)  (grid centre)\n', si, sj);
    fprintf('Pickup L  : (%d, %d)\n', pickup(1,1), pickup(1,2));
    fprintf('Pickup R  : (%d, %d)\n\n', pickup(2,1), pickup(2,2));
    fprintf('Running simulation...\n');

    % ---- Time-march, collecting audio and snapshots -----------------------
    n_samples  = round(P.duration * P.fs);
    snap_every = max(1, round(10e-3 * P.fs));   % snapshot every 10 ms

    audio = zeros(n_samples, size(pickup, 1));
    snaps = {};
    for n = 1:n_samples
        audio(n, :) = mesh.sample(pickup).';
        if mod(n - 1, snap_every) == 0
            snaps{end+1} = mesh.u; %#ok<AGROW>
        end
        mesh.step();
    end

    if ~exist(P.outdir, 'dir'); mkdir(P.outdir); end
    fprintf('Writing outputs:\n');
    save_wav(fullfile(P.outdir, sprintf('impulse_%s.wav', bc)), audio, P.fs);
    save_animation(fullfile(P.outdir, sprintf('displacement_%s.gif', bc)), ...
                   snaps, P);
    fprintf('Done.\n');
end

% ===========================================================================
% Helpers
% ===========================================================================

function bc = bc_name(free)
    if free; bc = 'free'; else; bc = 'fixed'; end
end

function P = parse_opts(P, args)
    if mod(numel(args), 2) ~= 0
        error('fdtd_ref:args', 'Options must be name/value pairs.');
    end
    for i = 1:2:numel(args)
        name = lower(args{i});
        val  = args{i+1};
        switch name
            case 'free';     P.free     = logical(val);
            case 'duration'; P.duration = val;
            case 'sigma';    P.sigma    = val;
            case 'c';        P.c        = val;
            case 'outdir';   P.outdir   = val;
            otherwise
                error('fdtd_ref:args', 'Unknown option "%s".', args{i});
        end
    end
end

function save_wav(path, audio, fs)
    % Write normalised stereo (or mono) 16-bit PCM WAV.
    peak = max(abs(audio(:)));
    if peak > 1e-12
        data = audio ./ peak;
    else
        data = audio;
    end
    data = max(min(data, 1.0), -1.0);
    audiowrite(path, data, fs, 'BitsPerSample', 16);
    nch = size(audio, 2);
    fprintf('  wrote %s  (%dch, %d Hz, %d frames)\n', ...
            path, nch, fs, size(audio, 1));
end

function save_animation(path, snaps, P)
    % Save a false-colour displacement animation as an animated GIF.
    % Guarded: if GIF writing is unavailable, skip with a warning rather
    % than failing the whole run (the animation is a sanity-check aid).
    try
        nframes = numel(snaps);
        vmax = 0;
        for f = 1:nframes
            vmax = max(vmax, max(abs(snaps{f}(:))));
        end
        if vmax == 0; vmax = 1.0; end

        cmap = redblue(256);
        delay = 1 / 25;   % 25 fps
        for f = 1:nframes
            % Map displacement [-vmax, vmax] -> colormap index [1, 256].
            norm = (snaps{f} + vmax) / (2 * vmax);     % -> [0, 1]
            idx  = uint8(round(norm * 255));           % -> [0, 255]
            idx  = flipud(idx);                        % origin lower
            if f == 1
                imwrite(idx, cmap, path, 'gif', ...
                        'LoopCount', Inf, 'DelayTime', delay);
            else
                imwrite(idx, cmap, path, 'gif', ...
                        'WriteMode', 'append', 'DelayTime', delay);
            end
        end
        fprintf('  wrote %s  (%d frames @ 25 fps)\n', path, nframes);
    catch err
        fprintf('  GIF writing unavailable (%s) - skipping animation.\n', ...
                err.message);
    end
end

function cmap = redblue(n)
    % Diverging blue-white-red colormap (approximates matplotlib RdBu_r).
    half = floor(n / 2);
    up   = linspace(0, 1, half).';
    down = linspace(1, 0, n - half).';
    r = [up;            ones(n - half, 1)];
    g = [up;            down];
    b = [ones(half, 1); down];
    cmap = [r, g, b];
end
