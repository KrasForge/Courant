classdef StiffMesh2D < handle
    % StiffMesh2D  2D FDTD with bending stiffness and anisotropy (issue #31).
    %
    % Extends the lossy wave equation of Mesh2D with a 4th-order bending term
    % (stiff plate / bar) and direction-dependent wave speed (anisotropy),
    % exploring "advanced materials" for milestone M9. Reference-model only:
    % this is the study vehicle for the go/no-go RTL recommendation, not RTL.
    %
    %   u_tt = cx^2 u_xx + cy^2 u_yy  -  kappa^2 (u_xxxx + 2 u_xxyy + u_yyyy)
    %          - 2 sigma u_t
    %
    % Explicit centred-difference update (k = 1/fs, h the spatial step):
    %
    %   u^{n+1} = a0 * ( 2u - sigk1 u^{n-1}
    %                    + g2x*Dxx(u) + g2y*Dyy(u)   (anisotropic Laplacian)
    %                    - mu2*Biharm(u) )           (bending stiffness)
    %
    %   g2x = (cx k / h)^2      x Courant number squared
    %   g2y = (cy k / h)^2      y Courant number squared
    %   mu2 = (kappa k / h^2)^2 stiffness number squared
    %
    % Discrete operators (zero-padded => fixed/supported edges u=0):
    %   Dxx = uE + uW - 2u                     (3-point)
    %   Dyy = uN + uS - 2u                     (3-point)
    %   Biharm = 20u - 8(N+S+E+W)
    %            + 2(NE+NW+SE+SW) + (NN+SS+EE+WW)   (13-point, = (Laplacian)^2)
    %
    % Stability (von Neumann; see docs/materials_stiffness.md for the derivation):
    %
    %   (g2x + g2y) + 16*mu2  <=  1
    %
    % which recovers the membrane CFL g^2 <= 1/2 when mu2 = 0 and g2x = g2y.
    %
    % Setting mu2 = 0 and g2x = g2y reduces this class exactly to Mesh2D
    % (fixed boundary). Handle class: step() mutates in place.

    properties
        nx
        ny
        g2x
        g2y
        mu2
        a0
        sigk1
        u
        u1
    end

    properties (Constant)
        % 13-point biharmonic stencil, = discrete (Laplacian)^2, 1/h^4 folded
        % into mu2. Symmetric, so conv2 orientation is irrelevant.
        BIHARM = [ 0  0  1  0  0
                   0  2 -8  2  0
                   1 -8 20 -8  1
                   0  2 -8  2  0
                   0  0  1  0  0 ];
        DXX = [0 0 0; 1 -2 1; 0 0 0];     % uE + uW - 2u
        DYY = [0 1 0; 0 -2 0; 0 1 0];     % uN + uS - 2u
    end

    methods
        function obj = StiffMesh2D(nx, ny, fs, h, cx, cy, kappa, sigma, check_cfl)
            % cx, cy : wave speeds in x / y (cx == cy => isotropic).
            % kappa  : bending-stiffness coefficient (0 => pure membrane).
            if nargin < 9 || isempty(check_cfl); check_cfl = true; end

            k = 1.0 / fs;
            obj.g2x = (cx * k / h)^2;
            obj.g2y = (cy * k / h)^2;
            obj.mu2 = (kappa * k / h^2)^2;

            stab = (obj.g2x + obj.g2y) + 16.0 * obj.mu2;
            if check_cfl && stab > 1.0
                error('StiffMesh2D:CFL', ...
                    ['Stability violated: (g2x+g2y)+16*mu2 = %.4f > 1 ' ...
                     '(g2x=%.4f g2y=%.4f mu2=%.5f). Reduce c or kappa, ' ...
                     'or increase h.'], stab, obj.g2x, obj.g2y, obj.mu2);
            end

            obj.nx = nx;  obj.ny = ny;
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
            % Advance one sample. Zero-padded conv2 ('same') = fixed edges u=0
            % (a simply-supported plate for the biharmonic term; see the doc for
            % the clamped-edge caveat).
            U = obj.u;
            Dxx = conv2(U, obj.DXX,    'same');
            Dyy = conv2(U, obj.DYY,    'same');
            B   = conv2(U, obj.BIHARM, 'same');

            u_next = obj.a0 .* (2.0 .* U - obj.sigk1 .* obj.u1 ...
                                + obj.g2x .* Dxx + obj.g2y .* Dyy ...
                                - obj.mu2 .* B);
            obj.u1 = U;
            obj.u  = u_next;
        end

        function vals = sample(obj, nodes)
            % Displacement at [row, col] pickup nodes (1-based), column vector.
            n = size(nodes, 1);
            vals = zeros(n, 1);
            for idx = 1:n
                vals(idx) = obj.u(nodes(idx, 1), nodes(idx, 2));
            end
        end
    end
end
