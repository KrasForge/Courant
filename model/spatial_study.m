function spatial_study(varargin)
% SPATIAL_STUDY  Spatially-varying coefficient exploration (issue #32).
%
% Reference-model study for "spatial parameter variation" (milestone M9,
% stretch):
%   A. confirms VarMesh2D reduces to Mesh2D when the coefficient maps are
%      uniform (correctness of the varying-coefficient model);
%   B. demonstrates musically useful profiles against a uniform baseline:
%        - radial damping (a damped rim: edges soak up energy, centre rings)
%        - tension gradient (wave speed rising across x: modes detune/spread)
%      reporting decay time and spectral centroid, and rendering audio;
%   C. prints the RTL storage/distribution cost of per-node coefficients and a
%      go/no-go, with the key finding that per-node maps are nearly free in the
%      time-multiplexed architecture (issue #24) and costly fully-spatial.
%
% Writes model/outputs/spatial_{uniform,radial_damp,tension_grad}.wav + stdout.
%
% Name/value options:
%   'outdir' (char)    output directory  [default model/outputs/]
%   'audio'  (logical) render the wavs    [default true]

    C.NX = 32;  C.NY = 32;
    C.FS = 48000;
    C.H  = 0.01;
    C.DUR   = 0.7;      % s
    C.PICK  = [];       % set below (centre-ish)

    P.outdir = fullfile(fileparts(mfilename('fullpath')), 'outputs');
    P.audio  = true;
    P = parse_opts(P, varargin);
    if ~exist(P.outdir, 'dir'); mkdir(P.outdir); end
    C.PICK = [round(C.NY/2)-4, round(C.NX/2)+3];

    fprintf('\n=== Spatial parameter variation study (issue #32) ===\n');
    fprintf('Grid %dx%d  fs=%g Hz  h=%g m\n', C.NX, C.NY, C.FS, C.H);

    part_A_reduces(C);
    part_B_profiles(C, P);
    part_C_cost();
end

% ===========================================================================
% A. VarMesh2D reduces to Mesh2D for uniform maps
% ===========================================================================
function part_A_reduces(C)
    fprintf('\n--- A. VarMesh2D == Mesh2D for uniform coefficients ---\n');
    c = 170; sigma = 1.0;
    a = Mesh2D(C.NX, C.NY, C.FS, C.H, c, sigma, 'fixed', true);
    b = VarMesh2D(C.NX, C.NY, C.FS, C.H, c, sigma, 'fixed', true);
    a.strike(round(C.NY/2), round(C.NX/2), 2, 1.0);
    b.strike(round(C.NY/2), round(C.NX/2), 2, 1.0);
    maxd = 0;
    for n = 1:400
        a.step(); b.step();
        maxd = max(maxd, max(abs(a.u(:) - b.u(:))));
    end
    fprintf('max |Mesh2D - VarMesh2D(uniform)| over 400 steps = %.3e  (%s)\n', ...
            maxd, tern(maxd < 1e-12, 'equivalent', 'MISMATCH'));
end

% ===========================================================================
% B. musical profiles
% ===========================================================================
function part_B_profiles(C, P)
    fprintf('\n--- B. spatial profiles vs uniform baseline ---\n');
    k = 1.0 / C.FS;

    % coordinate helpers (normalised radius 0 centre -> 1 corner)
    [jj, ii] = meshgrid(0:C.NX-1, 0:C.NY-1);
    cx0 = (C.NX-1)/2; cy0 = (C.NY-1)/2;
    rnorm = sqrt((ii-cy0).^2 + (jj-cx0).^2);
    rnorm = rnorm ./ max(rnorm(:));
    xnorm = jj ./ (C.NX-1);

    % three materials as (name, c_map, sigma_map)
    prof = {};
    prof{end+1} = {'uniform',      160,                       1.0};
    prof{end+1} = {'radial_damp',  160,                       1.0 + 60.0 .* rnorm.^2};
    prof{end+1} = {'tension_grad', 120 + 180 .* xnorm,        1.0};

    fprintf('%-14s  %10s  %14s\n', 'profile', 'decay(ms)', 'centroid(Hz)');
    fprintf('%s\n', repmat('-', 1, 42));
    for i = 1:numel(prof)
        name = prof{i}{1}; cmap = prof{i}{2}; smap = prof{i}{3};
        [sig, fs] = render(C, cmap, smap);
        dms = decay_ms(sig, fs);
        cen = centroid_hz(sig, fs);
        if P.audio
            audiowrite(fullfile(P.outdir, ['spatial_' name '.wav']), ...
                       0.9 * sig / max(abs(sig) + eps), fs);
        end
        fprintf('%-14s  %10.1f  %14.0f\n', name, dms, cen);
    end
    fprintf(['radial_damp: the rim soaks up energy -> a shorter, drier tail;\n' ...
             'tension_grad: the wave-speed ramp detunes the modes -> a higher,\n' ...
             'wider spectral centroid (richer, bell-like). Both are unreachable\n' ...
             'with a single global coefficient set.\n']);
end

function [sig, fs] = render(C, cmap, smap)
    fs = C.FS;
    m = VarMesh2D(C.NX, C.NY, fs, C.H, cmap, smap, 'fixed', true);
    m.strike(round(C.NY/2), round(C.NX/2), 1.5, 1.0);   % centre strike
    n = round(C.DUR * fs);
    sig = zeros(n, 1);
    for t = 1:n
        m.step();
        sig(t) = m.sample(C.PICK);
    end
end

% ===========================================================================
% C. RTL cost + recommendation
% ===========================================================================
function part_C_cost()
    fprintf('\n--- C. RTL storage/distribution cost + recommendation ---\n');
    fprintf([ ...
'Per-node coefficients turn the coefficient BUS into a coefficient MEMORY.\n' ...
'Storing gamma2/a0/sigk1 per node = 3 * NX*NY * 24 bits:\n' ...
'  8x8   -> 3*64*24   =  4.6 kbit   (< 1 BRAM)\n' ...
'  16x16 -> 3*256*24  =   18 kbit   (~1 BRAM)\n' ...
'  32x32 -> 3*1024*24 =   74 kbit   (~2 BRAM)\n' ...
'So storage itself is cheap. The cost is DISTRIBUTION, and it splits by\n' ...
'architecture:\n' ...
'  * time-multiplexed (issue #24): the PE already sweeps nodes by index, so a\n' ...
'    coeff RAM addressed by that same index is a near-FREE add (one extra\n' ...
'    read/port). Spatial variation is essentially a memory the sweep already\n' ...
'    has the address for.\n' ...
'  * fully-spatial: every node needs its own coeff registers/wires -> real\n' ...
'    area (3 extra Q1.23 regs/node) and routing; only sane for small grids.\n' ...
'Per-REGION (a small region-id map + a few coeff sets) is cheaper still and\n' ...
'covers most musical cases (rim vs centre, quadrants).\n\n']);
    fprintf('Recommendation: GO for the time-multiplexed path (per-node),\n');
    fprintf('                per-REGION for fully-spatial.\n');
    fprintf([ ...
'  Spatial variation is one of the cheapest high-impact features on the\n' ...
'  roadmap *if* built on the time-mux mesh: it reuses the node sweep index to\n' ...
'  address a coeff RAM, so a damped rim / tension gradient / stiffer centre\n' ...
'  costs ~1 BRAM and one port, no new arithmetic. Stability stays simple: the\n' ...
'  existing CFL clamp is applied per-node (max gamma2 <= gamma2_max). Gate on\n' ...
'  the time-mux mesh and the core hardware (#24, #26/#27) landing first.\n']);
end

% ===========================================================================
% helpers
% ===========================================================================
function dms = decay_ms(sig, fs)
    % time (ms) for the smoothed envelope to fall to 10% of its peak
    env = abs(hilbert_env(sig));
    w = max(1, round(2e-3 * fs));
    env = movmean_compat(env, w);
    [pk, ip] = max(env);
    if pk <= 0; dms = 0; return; end
    thr = 0.1 * pk;
    idx = find(env(ip:end) < thr, 1, 'first');
    if isempty(idx); dms = (numel(sig)-ip)/fs*1e3; else; dms = idx/fs*1e3; end
end

function e = hilbert_env(x)
    % |analytic signal| without the signal package: FFT-based Hilbert.
    x = x(:); N = numel(x);
    X = fft(x);
    h = zeros(N,1);
    if mod(N,2)==0
        h(1)=1; h(N/2+1)=1; h(2:N/2)=2;
    else
        h(1)=1; h(2:(N+1)/2)=2;
    end
    e = abs(ifft(X .* h));
end

function y = movmean_compat(x, w)
    % centred moving average (box), no toolbox dependency
    x = x(:); n = numel(x); y = zeros(n,1);
    c = cumsum([0; x]);
    half = floor(w/2);
    for i = 1:n
        lo = max(1, i-half); hi = min(n, i+half);
        y(i) = (c(hi+1) - c(lo)) / (hi - lo + 1);
    end
end

function f0 = centroid_hz(sig, fs)
    x = sig(:) .* (0.5 - 0.5*cos(2*pi*(0:numel(sig)-1)'/(numel(sig)-1)));
    N = 2^nextpow2(numel(x));
    X = abs(fft(x, N)); X = X(1:floor(N/2));
    f = (0:numel(X)-1)' * fs / N;
    lo = find(f >= 30, 1, 'first'); X(1:max(lo-1,1)) = 0;
    if sum(X) <= 0; f0 = 0; else; f0 = sum(f .* X) / sum(X); end
end

function out = tern(cond, a, b)
    if cond; out = a; else; out = b; end
end

function P = parse_opts(P, args)
    if mod(numel(args), 2) ~= 0
        error('spatial_study:args', 'Options must be name/value pairs.');
    end
    for i = 1:2:numel(args)
        switch lower(args{i})
            case 'outdir'; P.outdir = args{i+1};
            case 'audio';  P.audio  = logical(args{i+1});
            otherwise; error('spatial_study:args', 'Unknown option "%s".', args{i});
        end
    end
end
