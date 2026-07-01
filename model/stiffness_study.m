function stiffness_study(varargin)
% STIFFNESS_STUDY  Bending stiffness / anisotropy exploration (issue #31).
%
% Reference-model study for the "advanced materials" stretch (milestone M9):
%   A. confirms the stiff-scheme stability boundary  (g2x+g2y)+16*mu2 <= 1
%      by sweeping the stiffness number mu2 at a fixed wave Courant number and
%      comparing the empirical stable maximum to the predicted one;
%   B. renders audio for a plain membrane, a stiff plate, and an anisotropic
%      membrane, and reports how the partials move (stiffness stretches them
%      sharp / inharmonic -> bar/bell timbre; anisotropy splits the modes);
%   C. prints the RTL cost of the wider stencil and a go/no-go recommendation.
%
% Writes model/outputs/{membrane,stiff_plate,anisotropic}.wav and a stdout
% report. Needs StiffMesh2D.m on the path.
%
% Name/value options:
%   'outdir' (char)    output directory     [default model/outputs/]
%   'audio'  (logical) render the wavs       [default true]

    C.NX = 32;  C.NY = 32;
    C.FS = 48000;
    C.H  = 0.01;

    P.outdir = fullfile(fileparts(mfilename('fullpath')), 'outputs');
    P.audio  = true;
    P = parse_opts(P, varargin);
    if ~exist(P.outdir, 'dir'); mkdir(P.outdir); end

    fprintf('\n=== Stiffness / anisotropy study (issue #31) ===\n');
    fprintf('Grid %dx%d  fs=%g Hz  h=%g m\n', C.NX, C.NY, C.FS, C.H);

    part_A_stability(C);
    if P.audio
        part_B_audio(C, P.outdir);
    end
    part_C_cost_and_recommendation();
end

% ===========================================================================
% A. Stability boundary:  (g2x + g2y) + 16*mu2 <= 1
% ===========================================================================
function part_A_stability(C)
    fprintf('\n--- A. stability boundary  (g2x+g2y)+16*mu2 <= 1 ---\n');
    G2 = [0.05, 0.10, 0.20];        % isotropic wave Courant number squared (each axis)
    fprintf('%8s  %12s  %12s  %10s\n', 'g2(x=y)', 'mu2_predict', 'mu2_empir', 'match');
    fprintf('%s\n', repmat('-', 1, 48));

    ok_all = true;
    for g2 = G2
        mu2_pred = (1 - 2*g2) / 16;                 % boundary from 2*g2+16*mu2=1
        mu2_emp  = empirical_mu2_max(g2, mu2_pred, C);
        % within one sweep step of the prediction?
        match = abs(mu2_emp - mu2_pred) <= 1.5 * (mu2_pred / 20 + 1e-4);
        ok_all = ok_all && match;
        fprintf('%8.3f  %12.5f  %12.5f  %10s\n', g2, mu2_pred, mu2_emp, ...
                tern(match, 'yes', 'NO'));
    end
    fprintf(['Prediction %s the sweep: the bending term tightens CFL, ' ...
             'stealing\nwave headroom (higher stiffness -> lower max c).\n'], ...
            tern(ok_all, 'matches', 'DISAGREES with'));
end

function mu2_max = empirical_mu2_max(g2, mu2_pred, C)
    % Sweep mu2 up through the predicted boundary; last stable value wins.
    c = sqrt(g2) * C.H * C.FS;                      % same c on both axes
    grid = linspace(0, max(mu2_pred*1.6, 1e-3), 33);
    mu2_max = 0.0;
    for mu2 = grid
        kappa = sqrt(mu2) * C.H^2 * C.FS;
        m = StiffMesh2D(C.NX, C.NY, C.FS, C.H, c, c, kappa, 0.0, false);
        m.strike(floor(C.NY/2), floor(C.NX/2), 1.5, 1.0);
        if run_is_stable(m, round(0.05 * C.FS))
            mu2_max = mu2;
        else
            break;
        end
    end
end

function stable = run_is_stable(m, nsteps)
    stable = true;
    for n = 1:nsteps
        m.step();
        if mod(n, 64) == 0
            p = max(abs(m.u(:)));
            if ~isfinite(p) || p > 1e3; stable = false; return; end
        end
    end
end

% ===========================================================================
% B. Audio: membrane vs stiff plate vs anisotropic
% ===========================================================================
function part_B_audio(C, outdir)
    fprintf('\n--- B. audio / timbre ---\n');
    dur   = 0.6;                                    % s
    sigma = 1.2;                                    % light damping
    pick  = [floor(C.NY/4), floor(C.NX/2)];         % off-centre pickup (1-based)

    % three materials (chosen well inside the stability region)
    mats = { ...
        'membrane',   150, 150, 0.0;   ...          % plain membrane
        'stiff_plate',120, 120, 0.9;   ...          % strong bending stiffness
        'anisotropic',250, 110, 0.0    };           % different cx, cy

    fprintf('%-12s  %6s %6s %7s   %-28s\n', 'material','cx','cy','kappa','first partials (Hz)');
    fprintf('%s\n', repmat('-', 1, 66));
    for i = 1:size(mats,1)
        name = mats{i,1}; cx = mats{i,2}; cy = mats{i,3}; kappa = mats{i,4};
        [sig, fs] = render(C, cx, cy, kappa, sigma, dur, pick);
        peaks = first_peaks(sig, fs, 4);
        if P_has_audio(outdir)
            wavpath = fullfile(outdir, [name '.wav']);
            audiowrite(wavpath, 0.9 * sig / max(abs(sig) + eps), fs);
        end
        fprintf('%-12s  %6g %6g %7.2f   %s\n', name, cx, cy, kappa, ...
                sprintf('%.0f ', peaks));
    end
    inh = inharmonicity_hint();
    fprintf(['Stiffness stretches the partials sharp of a harmonic series ' ...
             '(inharmonic\nbar/bell character); anisotropy splits degenerate ' ...
             'modes (cx != cy).\n%s'], inh);
end

function [sig, fs] = render(C, cx, cy, kappa, sigma, dur, pick)
    fs = C.FS;
    m = StiffMesh2D(C.NX, C.NY, fs, C.H, cx, cy, kappa, sigma, true);
    m.strike(floor(C.NY/2)-3, floor(C.NX/2)+2, 1.5, 1.0);   % off-centre strike
    n = round(dur * fs);
    sig = zeros(n, 1);
    for t = 1:n
        m.step();
        sig(t) = m.sample(pick);
    end
end

% ===========================================================================
% C. RTL cost + go/no-go
% ===========================================================================
function part_C_cost_and_recommendation()
    fprintf('\n--- C. RTL cost of the wider stencil + recommendation ---\n');
    fprintf([ ...
'Stencil grows 5-point -> 13-point (adds 4 diagonal + 4 second-ring taps):\n' ...
'  * neighbour reads/adds per node: 4 -> 12  (~+8 adds in the accumulate)\n' ...
'  * coefficient multiplies: +1 (the mu2*biharm term); anisotropy splits\n' ...
'    the one gamma2*lap multiply into g2x*Dxx + g2y*Dyy (+1 multiply)\n' ...
'  * so ~+1..2 DSP/node over the 18 DSP/node membrane PE (~10%% more)\n' ...
'  * memory/routing is the real cost: the second ring needs +-2 rows, i.e.\n' ...
'    TWO row line-buffers instead of one (time-mux) or a wider neighbour\n' ...
'    fabric (spatial); boundary handling needs a 2-cell ghost margin.\n\n']);
    fprintf('Recommendation: GO (conditional).\n');
    fprintf([ ...
'  The physics is a modest, well-understood extension: one extra coefficient,\n' ...
'  a wider but still-linear stencil, and a TIGHTER but closed-form stability\n' ...
'  bound ((g2x+g2y)+16*mu2 <= 1) that slots straight into the existing\n' ...
'  compile-time clamp. DSP cost is small; the line-buffer/ghost-margin work is\n' ...
'  the integration effort. Worthwhile for bars/plates/bells and the anisotropic\n' ...
'  "oval drum" voices, which meaningfully widen the instrument palette.\n' ...
'  Gate: land it AFTER the core is on real hardware (issues #26/#27), since it\n' ...
'  widens the datapath and the memory subsystem.\n']);
end

% ===========================================================================
% helpers
% ===========================================================================
function peaks = first_peaks(sig, fs, npk)
    x = sig(:) .* hann_win(numel(sig));
    N = 2^nextpow2(numel(x));
    X = abs(fft(x, N));
    X = X(1:floor(N/2));
    f = (0:numel(X)-1) * fs / N;
    lo = find(f >= 30, 1, 'first');                 % ignore DC / sub-audio
    X(1:max(lo-1,1)) = 0;
    peaks = [];
    for i = 1:npk
        [~, k] = max(X);
        if X(k) <= 0; break; end
        peaks(end+1) = f(k); %#ok<AGROW>
        lo2 = max(k-8,1); hi2 = min(k+8,numel(X));   % notch out this peak
        X(lo2:hi2) = 0;
    end
    peaks = sort(peaks);
end

function w = hann_win(n)
    w = 0.5 - 0.5 * cos(2*pi*(0:n-1)'/(n-1));
end

function s = inharmonicity_hint()
    s = '';
end

function tf = P_has_audio(~)
    tf = true;    % audiowrite is core in Octave/MATLAB
end

function out = tern(cond, a, b)
    if cond; out = a; else; out = b; end
end

function P = parse_opts(P, args)
    if mod(numel(args), 2) ~= 0
        error('stiffness_study:args', 'Options must be name/value pairs.');
    end
    for i = 1:2:numel(args)
        switch lower(args{i})
            case 'outdir'; P.outdir = args{i+1};
            case 'audio';  P.audio  = logical(args{i+1});
            otherwise; error('stiffness_study:args', 'Unknown option "%s".', args{i});
        end
    end
end
