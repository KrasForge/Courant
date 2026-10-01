classdef QMesh2D < handle
    % QMesh2D  Q1.23 fixed-point quantized variant of the 2D FDTD mesh.
    %
    % Mirrors Mesh2D (the floating-point golden reference) but performs the
    % node update with the signed Q1.23 saturating datapath the RTL will use
    % (README §4):
    %
    %   Format      : signed Q1.23 (24-bit two's complement), range [-1, +1)
    %   Multiply    : Q1.23 x Q1.23 -> Q2.46, rescaled by >>23, then used
    %   Accumulate  : wide 48-bit guard accumulator, saturated on store
    %   Overflow    : saturating arithmetic (graceful soft-clip, never wrap)
    %
    % The state is held as INTEGERS at the Q.frac scale (value = int * 2^-frac).
    % MATLAB doubles represent these integers exactly (|value| < 2^48 << 2^53),
    % so the "48-bit guard accumulator" is modelled exactly.
    %
    % Construction options (name/value, after the boundary argument):
    %   'frac'       fractional bits of the state/datapath   [default 23]
    %   'coeff_frac' fractional bits of a0/sigk1/gamma2       [default = frac]
    %   'rounding'   'round' (nearest) or 'truncate' (>>, toward -inf)
    %                                                          [default 'round']
    %
    % Diagnostics collected during a run:
    %   sat_count    number of state elements saturated on store
    %   acc_absmax   largest |accumulator| seen (in real units) -> guard bits

    properties
        nx
        ny
        boundary
        frac
        one          % 2^frac
        half         % 2^(frac-1), for round-to-nearest
        smax         % +2^frac - 1   (Q1.23 upper saturation, integer)
        smin         % -2^frac       (Q1.23 lower saturation, integer)
        rounding
        a0q          % quantized coefficients, expressed at Q.frac integer scale
        sigk1q
        gamma2q
        s            % state u^n   (integer, Q.frac)
        s1           % state u^n-1 (integer, Q.frac)
        sat_count
        acc_absmax
    end

    methods
        function obj = QMesh2D(nx, ny, fs, h, c, sigma, boundary, varargin)
            if nargin < 7 || isempty(boundary); boundary = 'fixed'; end
            opt.frac       = 23;
            opt.coeff_frac = [];
            opt.rounding   = 'round';
            opt = parse_local(opt, varargin);
            if isempty(opt.coeff_frac); opt.coeff_frac = opt.frac; end

            k = 1.0 / fs;
            gamma2 = (c * k / h) ^ 2;
            a0     = 1.0 / (1.0 + sigma * k);
            sigk1  = 1.0 - sigma * k;

            obj.nx = nx;  obj.ny = ny;  obj.boundary = boundary;
            obj.frac = opt.frac;
            obj.one  = 2 ^ opt.frac;
            obj.half = 2 ^ (opt.frac - 1);
            obj.smax = 2 ^ opt.frac - 1;
            obj.smin = -2 ^ opt.frac;
            obj.rounding = opt.rounding;

            obj.a0q     = obj.qcoeff(a0,     opt.coeff_frac);
            obj.sigk1q  = obj.qcoeff(sigk1,  opt.coeff_frac);
            obj.gamma2q = obj.qcoeff(gamma2, opt.coeff_frac);

            obj.s  = zeros(ny, nx);
            obj.s1 = zeros(ny, nx);
            obj.sat_count  = 0;
            obj.acc_absmax = 0;
        end

        function strike(obj, si, sj, radius, amp)
            % Gaussian impulse, quantized to Q1.23 on entry (matches Mesh2D).
            if nargin < 4 || isempty(radius); radius = 2.0; end
            if nargin < 5 || isempty(amp);    amp    = 1.0; end
            [jj, ii] = meshgrid(0:obj.nx-1, 0:obj.ny-1);
            d2 = (ii - si).^2 + (jj - sj).^2;
            f  = amp .* exp(-d2 ./ (2.0 .* radius.^2));
            obj.s = obj.satint(obj.rescale_from_real(f));
        end

        function step(obj)
            ny = obj.ny; nx = obj.nx;
            S = obj.s;

            % Boundary ghosts (integer state; N/S/E/W stencil only).
            P = zeros(ny + 2, nx + 2);
            P(2:ny+1, 2:nx+1) = S;
            if ~strcmp(obj.boundary, 'fixed')
                P(1,      2:nx+1) = S(2,    :);
                P(ny+2,   2:nx+1) = S(ny-1, :);
                P(2:ny+1, 1)      = S(:,    2);
                P(2:ny+1, nx+2)   = S(:,    nx-1);
            end

            % Laplacian: exact integer sum at Q.frac (no rounding).
            lap = P(3:ny+2, 2:nx+1) + P(1:ny,   2:nx+1) ...
                + P(2:ny+1, 3:nx+2) + P(2:ny+1, 1:nx) ...
                - 4.0 .* P(2:ny+1, 2:nx+1);

            % gamma^2 * lap  and  sigk1 * u^{n-1}: Q.frac x Q.frac -> >>frac.
            gl  = obj.mulq(obj.gamma2q, lap);
            su1 = obj.mulq(obj.sigk1q,  obj.s1);

            % Guard accumulator: 2u - sigk1*u1 + gamma2*lap  (integer Q.frac).
            acc = 2.0 .* S - su1 + gl;
            obj.acc_absmax = max(obj.acc_absmax, max(abs(acc(:))) / obj.one);

            % Final scale by a0, then saturate to Q1.23 on store.
            out = obj.mulq(obj.a0q, acc);
            [sn, nsat] = obj.satint(out);
            obj.sat_count = obj.sat_count + nsat;

            obj.s1 = S;
            obj.s  = sn;
        end

        function vals = sample(obj, nodes)
            % Real-valued displacement at [row,col] pickup nodes (column vec).
            n = size(nodes, 1);
            vals = zeros(n, 1);
            for idx = 1:n
                vals(idx) = obj.s(nodes(idx, 1), nodes(idx, 2)) / obj.one;
            end
        end
    end

    % -- fixed-point primitives --------------------------------------------
    methods (Access = private)
        function r = mulq(obj, aq, bq)
            % (aq * bq) is Q(2*frac); rescale by >>frac to Q.frac.
            p = aq .* bq;
            if strcmp(obj.rounding, 'round')
                r = floor((p + obj.half) ./ obj.one);   % round half up
            else
                r = floor(p ./ obj.one);                 % arithmetic >> (toward -inf)
            end
        end

        function [r, nsat] = satint(obj, x)
            % Saturate integer Q.frac value to the Q1.23 representable range.
            r = max(min(x, obj.smax), obj.smin);
            if nargout > 1
                nsat = sum(x(:) > obj.smax) + sum(x(:) < obj.smin);
            end
        end

        function xi = rescale_from_real(obj, xf)
            if strcmp(obj.rounding, 'round')
                xi = round(xf .* obj.one);
            else
                xi = floor(xf .* obj.one);
            end
        end

        function q = qcoeff(obj, x, cfrac)
            % Quantize coefficient x to cfrac fractional bits, then express
            % at the Q.frac integer scale used by mulq.
            stepv = 2 ^ (obj.frac - cfrac);
            qi    = round(x .* 2 ^ cfrac);
            q     = qi .* stepv;
        end
    end
end

% ---------------------------------------------------------------------------
function opt = parse_local(opt, args)
    if mod(numel(args), 2) ~= 0
        error('QMesh2D:args', 'Options must be name/value pairs.');
    end
    for i = 1:2:numel(args)
        name = lower(args{i});
        if ~isfield(opt, name)
            error('QMesh2D:args', 'Unknown option "%s".', args{i});
        end
        opt.(name) = args{i+1};
    end
end
