classdef NLMesh2D < handle
    % NLMesh2D  2D FDTD with the non-linear chaos term (issue #71).
    %
    % Extends the linear Mesh2D with the amplitude-dependent stiffening of
    % README §2 (the same non-linearity as the RTL node_element):
    %
    %   gamma2_local(i,j) = clamp(gamma0^2 + alpha*u(i,j)^2, 0, gamma2_max)
    %   u^{n+1} = a0*( 2u - sigk1*u^{n-1} + gamma2_local .* Lap(u) )
    %
    % A louder node stiffens (its local Courant number rises), which folds
    % harmonics and gives the "chaos" timbre; the CFL-safe clamp gamma2_max
    % (< 1/2, issue #3) keeps it bounded at any amplitude. With alpha = 0 and
    % gamma2_max >= gamma2 this reduces exactly to the linear Mesh2D.
    %
    % This is the float reference model, used for the demo audio (demo_render).
    % For a BIT-EXACT match to the Q1.23 RTL, see nl_reference.m, which
    % regenerates the RTL golden trace with fixed-point arithmetic.
    %
    % Coefficients are set directly (gamma2, alpha, gamma2_max) rather than from
    % physical units, so a note's pitch/timbre map straight onto them (as on the
    % control bus). Handle class: step() mutates in place.

    properties
        nx
        ny
        boundary
        gamma2
        alpha
        gamma2_max
        a0
        sigk1
        u
        u1
    end

    methods
        function obj = NLMesh2D(nx, ny, fs, gamma2, alpha, gamma2_max, sigma, boundary)
            if nargin < 8 || isempty(boundary); boundary = 'fixed'; end
            k = 1.0 / fs;
            obj.nx = nx;  obj.ny = ny;  obj.boundary = boundary;
            obj.gamma2     = gamma2;
            obj.alpha      = alpha;
            obj.gamma2_max = gamma2_max;
            obj.a0    = 1.0 / (1.0 + sigma * k);
            obj.sigk1 = 1.0 - sigma * k;
            obj.u  = zeros(ny, nx);
            obj.u1 = zeros(ny, nx);
        end

        function strike(obj, si, sj, radius, amp)
            % Gaussian displacement impulse centred on (si, sj), 0-indexed.
            if nargin < 4 || isempty(radius); radius = 2.0; end
            if nargin < 5 || isempty(amp);    amp    = 1.0; end
            [jj, ii] = meshgrid(0:obj.nx-1, 0:obj.ny-1);
            d2 = (ii - si).^2 + (jj - sj).^2;
            obj.u = obj.u + amp .* exp(-d2 ./ (2.0 .* radius.^2));
        end

        function step(obj)
            ny = obj.ny; nx = obj.nx;
            U = obj.u;

            UP = zeros(ny + 2, nx + 2);
            UP(2:ny+1, 2:nx+1) = U;
            if ~strcmp(obj.boundary, 'fixed')
                UP(1,      2:nx+1) = U(2,    :);
                UP(ny+2,   2:nx+1) = U(ny-1, :);
                UP(2:ny+1, 1)      = U(:,    2);
                UP(2:ny+1, nx+2)   = U(:,    nx-1);
            end

            lap = UP(3:ny+2, 2:nx+1) + UP(1:ny,   2:nx+1) ...
                + UP(2:ny+1, 3:nx+2) + UP(2:ny+1, 1:nx) ...
                - 4.0 .* UP(2:ny+1, 2:nx+1);

            % amplitude-dependent local stiffness, CFL-clamped (per node)
            g2l = min(max(obj.gamma2 + obj.alpha .* U.^2, 0.0), obj.gamma2_max);

            u_next = obj.a0 .* (2.0 .* U - obj.sigk1 .* obj.u1 + g2l .* lap);
            % saturate the stored displacement to the Q1.23 rails, mirroring the
            % RTL sat_store: part of what bounds the non-linear scheme (without
            % it a hard strike overshoots into an unphysical, chaotic regime).
            u_next = min(max(u_next, -1.0), 1.0 - 2^-23);
            obj.u1 = U;
            obj.u  = u_next;
        end

        function vals = sample(obj, nodes)
            n = size(nodes, 1);
            vals = zeros(n, 1);
            for idx = 1:n
                vals(idx) = obj.u(nodes(idx, 1), nodes(idx, 2));
            end
        end
    end
end
