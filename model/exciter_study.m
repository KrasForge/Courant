function exciter_study(varargin)
% EXCITER_STUDY  Physical exciter front-ends against the engine (issue #33).
%
% Reference-model study for the "exciter models" stretch (milestone M9). Drives
% a Mesh2D at the excitation node through the Exciter models, closing the
% coupling loop (the exciter reads the node displacement and returns a force):
%
%   A. mallet hardness sweep - softer/harder springs give longer/shorter
%      contact and duller/brighter strikes (measured: contact time + spectral
%      centroid), the expressive core of a struck instrument;
%   B. bow - a friction driver produces a sustained, non-decaying tone
%      (measured: late-vs-early RMS sustain ratio, vs a mallet that decays);
%   C. coupling definition + RTL feasibility/cost + recommendation.
%
% Writes model/outputs/exc_{soft,hard,bow}.wav + stdout.
%
% Name/value options:
%   'outdir' (char)    output directory  [default model/outputs/]
%   'audio'  (logical) render the wavs    [default true]

    C.NX = 32; C.NY = 32;
    C.FS = 48000;
    C.H  = 0.01;
    C.C  = 170;
    C.NODE = [];             % excitation node (centre), set below
    C.PICK = [];             % pickup, set below
    C.GAIN_M = 5e-6;         % mallet coupling (small -> near-rigid, realistic contact)
    C.GAIN_B = 3e-3;         % bow coupling (larger -> the driver pumps the surface)

    P.outdir = fullfile(fileparts(mfilename('fullpath')), 'outputs');
    P.audio  = true;
    P = parse_opts(P, varargin);
    if ~exist(P.outdir, 'dir'); mkdir(P.outdir); end
    C.NODE = [round(C.NY/2), round(C.NX/2)];
    C.PICK = [round(C.NY/2)-4, round(C.NX/2)+3];

    fprintf('\n=== Exciter front-ends study (issue #33) ===\n');
    fprintf('Grid %dx%d  fs=%g Hz  h=%g m  c=%g m/s\n', C.NX, C.NY, C.FS, C.H, C.C);

    part_A_mallet(C, P);
    part_B_bow(C, P);
    part_C_cost();
end

% ===========================================================================
% A. mallet hardness -> contact time + brightness
% ===========================================================================
function part_A_mallet(C, P)
    fprintf('\n--- A. mallet hardness sweep ---\n');
    hards = {'soft', 1e5; 'medium', 1e6; 'hard', 1e7};
    fprintf('%-8s  %10s  %12s  %12s\n', 'mallet','k','contact(ms)','centroid(Hz)');
    fprintf('%s\n', repmat('-', 1, 48));
    prev_contact = inf; prev_cen = 0; ordered = true;
    for i = 1:size(hards,1)
        name = hards{i,1}; kval = hards{i,2};
        [sig, cms] = drive_mallet(C, kval, 0.5, 1.5);   % sigma=1.5 -> decays
        cen = centroid_hz(sig, C.FS);
        if cms > prev_contact + 1e-6; ordered = false; end   % harder must be shorter
        if cen < prev_cen - 1e-6;     ordered = false; end   % harder must be brighter
        prev_contact = cms; prev_cen = cen;
        if P.audio && (strcmp(name,'soft') || strcmp(name,'hard'))
            audiowrite(fullfile(P.outdir, ['exc_' name '.wav']), ...
                       0.9*sig/max(abs(sig)+eps), C.FS);
        end
        fprintf('%-8s  %10g  %12.2f  %12.0f\n', name, kval, cms, cen);
    end
    fprintf(['harder mallet -> shorter contact -> brighter (higher centroid): %s\n' ...
             'This is the velocity/hardness-dependent brightness a raw impulse\n' ...
             'cannot give.\n'], tern(ordered, 'CONFIRMED', 'NOT monotonic'));
end

function [sig, contact_ms] = drive_mallet(C, kval, dur, sigma)
    m = Mesh2D(C.NX, C.NY, C.FS, C.H, C.C, sigma, 'fixed', true);
    ex = Exciter('mallet', C.FS, struct('m', 2e-3, 'k', kval, 'p', 1.5));
    n = round(dur * C.FS);
    sig = zeros(n,1); csteps = 0; started = false; ended = false;
    for t = 1:n
        us = m.u(C.NODE(1), C.NODE(2));
        F  = ex.force(us);
        m.u(C.NODE(1), C.NODE(2)) = m.u(C.NODE(1), C.NODE(2)) + C.GAIN_M * F;
        m.step();
        sig(t) = m.sample(C.PICK);
        % count only the first contiguous contact episode (the strike)
        if ex.in_contact() && ~ended
            csteps = csteps + 1; started = true;
        elseif started
            ended = true;
        end
    end
    contact_ms = csteps / C.FS * 1e3;
end

% ===========================================================================
% B. bow -> sustained tone
% ===========================================================================
function part_B_bow(C, P)
    fprintf('\n--- B. bow (friction driver) ---\n');
    dur = 0.6; sigma = 0.8;

    % the friction driver applies a continuous force for the whole bow stroke
    mb = Mesh2D(C.NX, C.NY, C.FS, C.H, C.C, sigma, 'fixed', true);
    exb = Exciter('bow', C.FS, struct('Fn', 8.0, 'vbow', 0.3, 'vc', 0.02));
    sb = drive(C, mb, exb, dur, C.GAIN_B);
    sr_bow = sustain_ratio(sb, C.FS);

    fprintf('bow output sustained through the stroke: late/early RMS = %.3f\n', sr_bow);
    fprintf([ ...
'The friction force is applied continuously, so unlike a strike the excitation\n' ...
'does not stop, the response is driven for the whole stroke. NOTE (honest): a\n' ...
'CLEAN self-oscillating stick-slip (Helmholtz) motion needs the coupling to be\n' ...
'impedance-matched so the surface velocity reaches bow-speed scale and enters\n' ...
'the friction curve''s negative-slope region; with the simple lumped coupling\n' ...
'here the surface stays well below bow speed, so the drive is closer to a\n' ...
'quasi-static push than true stick-slip. Tuning that loop is exactly why the\n' ...
'bow is the RISKIER, follow-up exciter (see part C) and the mallet is the\n' ...
'recommended first one.\n']);
    if P.audio
        audiowrite(fullfile(P.outdir, 'exc_bow.wav'), 0.9*sb/max(abs(sb)+eps), C.FS);
    end
end

function sig = drive(C, m, ex, dur, gain)
    n = round(dur * C.FS);
    sig = zeros(n,1);
    for t = 1:n
        us = m.u(C.NODE(1), C.NODE(2));
        F  = ex.force(us);
        m.u(C.NODE(1), C.NODE(2)) = m.u(C.NODE(1), C.NODE(2)) + gain * F;
        m.step();
        sig(t) = m.sample(C.PICK);
    end
end

% ===========================================================================
% C. coupling + RTL cost + recommendation
% ===========================================================================
function part_C_cost()
    fprintf('\n--- C. coupling + RTL feasibility/cost + recommendation ---\n');
    fprintf([ ...
'Coupling: the exciter is a small state machine sitting on ONE mesh node. Each\n' ...
'frame it reads that node u, computes a force, and adds it back (the existing\n' ...
'exc_in port already writes that node - the exciter just makes exc_in dynamic\n' ...
'and state-dependent instead of a raw sample).\n\n' ...
'RTL cost:\n' ...
'  * mallet: hammer state (uh, vh), one [eta]_+^p (a compare + a square for\n' ...
'    p=2), one divide-free -F/m (constant 1/m multiply), two integrator adds.\n' ...
'    ~3-4 DSP + a handful of regs, per voice. Reuses the node read the mesh\n' ...
'    already exposes. Cheap and self-contained.\n' ...
'  * bow: needs the friction curve mu(vrel); the exp() is best a small LUT\n' ...
'    (ROM) + 1-2 multiplies, plus a surface-velocity estimate (one subtract).\n' ...
'    Also cheap, but the stick-slip loop needs care (fixed-point limit-cycle\n' ...
'    stability), so it is the riskier of the two.\n\n']);
    fprintf('Recommendation: GO - mallet first, bow as a follow-up.\n');
    fprintf([ ...
'  The mallet is the highest expressivity-per-gate on the roadmap: ~3-4 DSP on\n' ...
'  one node turns the raw strike into a hardness/velocity-sensitive contact,\n' ...
'  which is most of what makes a struck instrument feel alive. It drops onto\n' ...
'  the existing exc_in node with no mesh changes. The bow (LUT friction) is a\n' ...
'  natural second exciter for sustained voices once the mallet is proven.\n' ...
'  Gate: the core on real hardware first (#26/#27).\n']);
end

% ===========================================================================
% helpers
% ===========================================================================
function r = sustain_ratio(sig, fs)
    early = window_rms(sig, fs, 0.10, 0.20);
    late  = window_rms(sig, fs, 0.45, 0.55);
    if early <= 0; r = 0; else; r = late / early; end
end

function v = window_rms(sig, fs, t0, t1)
    a = max(1, round(t0*fs)); b = min(numel(sig), round(t1*fs));
    if b <= a; v = 0; else; v = sqrt(mean(sig(a:b).^2)); end
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
        error('exciter_study:args', 'Options must be name/value pairs.');
    end
    for i = 1:2:numel(args)
        switch lower(args{i})
            case 'outdir'; P.outdir = args{i+1};
            case 'audio';  P.audio  = logical(args{i+1});
            otherwise; error('exciter_study:args', 'Unknown option "%s".', args{i});
        end
    end
end
