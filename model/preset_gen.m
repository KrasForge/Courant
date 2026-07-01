function preset_gen(varargin)
% PRESET_GEN  Author a Courant preset from physical parameters (MATLAB/Octave).
%
% Computes the Q1.23 register words for the preset_bank register layout (issue
% #30) from the physical instrument parameters, so presets can be authored from
% meaningful units (wave speed, damping, chaos coupling, tap positions) instead
% of raw fixed-point. Prints the 10-word bundle ready to paste into the factory
% table in src/rtl/preset_bank.vhd or to write over the control bus.
%
% Name/value options (all optional):
%   'name'  (char) preset name, for the printout           [default 'custom']
%   'fs'    (Hz)   audio sample rate                        [default 48000]
%   'os'    (int)  oversampling factor (mesh steps/frame)   [default 4]
%   'h'     (m)    spatial step                             [default 0.01]
%   'c'     (m/s)  wave speed (sets pitch/tension)          [default 200]
%   'sigma' (1/s)  damping (sets decay time)                [default 1.5]
%   'alpha' (-)    chaos coupling (timbre)                  [default 0.1]
%   'g2max' (-)    CFL-safe clamp ceiling (< 0.5)           [default 0.451]
%   'taps'  (1x4)  [Lx Ly Rx Ry] pickup coordinates         [default [2 4 6 4]]
%   'free'  (bool) free (Neumann) boundary                  [default false]
%
% The coefficients follow README §4: gamma2 = (c*(k/os)/h)^2, a0 = 1/(1+sigma*k'),
% sigk1 = 1 - sigma*k', with k' = (1/fs)/os the oversampled time step.
%
% Example:
%   preset_gen('name','gong','c',245,'sigma',0.05,'alpha',0.40,'free',true)

    p = inputParser;
    p.addParameter('name', 'custom', @ischar);
    p.addParameter('fs', 48000, @isnumeric);
    p.addParameter('os', 4, @isnumeric);
    p.addParameter('h', 0.01, @isnumeric);
    p.addParameter('c', 200, @isnumeric);
    p.addParameter('sigma', 1.5, @isnumeric);
    p.addParameter('alpha', 0.1, @isnumeric);
    p.addParameter('g2max', 0.451, @isnumeric);
    p.addParameter('taps', [2 4 6 4], @isnumeric);
    p.addParameter('free', false, @(x) islogical(x) || isnumeric(x));
    p.parse(varargin{:});
    o = p.Results;

    kp     = (1 / o.fs) / o.os;          % oversampled time step
    gamma2 = (o.c * kp / o.h)^2;         % base Courant number squared
    a0     = 1 / (1 + o.sigma * kp);
    sigk1  = 1 - o.sigma * kp;

    if gamma2 >= o.g2max
        warning('preset_gen:cfl', ...
            'gamma2 = %.4f >= gamma2_max = %.4f: reduce c or h (CFL).', ...
            gamma2, o.g2max);
    end

    q = @(x) q123_hex(x);                % Q1.23 hex helper (below)

    fprintf('\n-- preset "%s"  (c=%g sigma=%g alpha=%g free=%d)\n', ...
            o.name, o.c, o.sigma, o.alpha, o.free);
    fprintf('--   gamma2  a0        sigk1     alpha  g2max  Lx Ly Rx Ry free\n');
    fprintf('mk(%.4f, %.6f, %.6f, %.4f, %.4f,  %d, %d, %d, %d, %d)\n', ...
            gamma2, a0, sigk1, o.alpha, o.g2max, ...
            o.taps(1), o.taps(2), o.taps(3), o.taps(4), double(o.free));

    fprintf('\n-- register words (addr : Q1.23 hex) to write over the bus:\n');
    names = {'gamma2','a0','sigk1','alpha','gamma2_max'};
    vals  = [gamma2, a0, sigk1, o.alpha, o.g2max];
    for i = 1:5
        fprintf('   %2d  %-10s 0x%s\n', i-1, names{i}, q(vals(i)));
    end
    coords = {'pick_lx','pick_ly','pick_rx','pick_ry'};
    for i = 1:4
        fprintf('   %2d  %-10s 0x%06X\n', 4+i, coords{i}, o.taps(i));
    end
    fprintf('    9  boundary   0x%06X\n\n', double(o.free ~= 0));
end

function s = q123_hex(x)
% Quantize a real to Q1.23, round-to-nearest, saturate, return 6-hex-digit chars.
    v = round(x * 2^23);
    v = max(min(v, 2^23 - 1), -2^23);   % saturate to [-1, 1)
    if v < 0, v = v + 2^24; end          % two's complement, 24-bit
    s = sprintf('%06X', v);
end
