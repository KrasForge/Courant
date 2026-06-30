classdef Mesh2D < handle
    % Mesh2D  Explicit finite-difference 2D lossy wave equation on a grid.
    %
    % Implements the explicit centred-difference update from README §1:
    %
    %   u(i,j)^{n+1} = a0 * ( 2*u(i,j)^n  -  sigk1*u(i,j)^{n-1}
    %                         + gamma^2 * Lap(u(i,j)^n) )
    %
    %   Lap(u)(i,j) = u(i+1,j) + u(i-1,j) + u(i,j+1) + u(i,j-1) - 4*u(i,j)
    %
    %   gamma  = c * k / h          Courant number; stable when gamma^2 <= 0.5
    %   a0     = 1 / (1 + sigma*k)  forward coefficient
    %   sigk1  = 1 - sigma*k        backward coefficient
    %   k      = 1 / fs             time step
    %
    % Boundaries
    %   'fixed' : Dirichlet u=0 (clamped edges — frame drum)
    %   'free'  : Neumann du/dn=0 (mirrored ghost — free plate)
    %
    % This is a handle class so step() mutates the object in place.
    %
    % Properties
    %   u  : (ny, nx) displacement at time n
    %   u1 : (ny, nx) displacement at time n-1

    properties
        nx
        ny
        boundary
        gamma2
        a0
        sigk1
        u
        u1
    end

    methods
        function obj = Mesh2D(nx, ny, fs, h, c, sigma, boundary, check_cfl)
            if nargin < 7 || isempty(boundary); boundary = 'fixed'; end
            if nargin < 8 || isempty(check_cfl); check_cfl = true; end

            k = 1.0 / fs;
            gamma2 = (c * k / h) ^ 2;
            if check_cfl && gamma2 > 0.5
                error('Mesh2D:CFL', ...
                    ['CFL violated: gamma^2=%.4f > 0.5 ' ...
                     '(c=%g m/s, h=%g m, fs=%g Hz). Reduce c or increase h.'], ...
                    gamma2, c, h, fs);
            end

            obj.nx = nx;
            obj.ny = ny;
            obj.boundary = boundary;
            obj.gamma2 = gamma2;
            obj.a0     = 1.0 / (1.0 + sigma * k);
            obj.sigk1  = 1.0 - sigma * k;

            obj.u  = zeros(ny, nx);
            obj.u1 = zeros(ny, nx);
        end

        function strike(obj, si, sj, radius, amp)
            % Apply a Gaussian displacement impulse centred on node (si, sj).
            % si, sj are 0-indexed grid coordinates (matching the field math),
            % radius is the Gaussian half-width in cells, amp the peak height.
            if nargin < 4 || isempty(radius); radius = 2.0; end
            if nargin < 5 || isempty(amp);    amp    = 1.0; end
            [jj, ii] = meshgrid(0:obj.nx-1, 0:obj.ny-1);
            d2 = (ii - si).^2 + (jj - sj).^2;
            obj.u = obj.u + amp .* exp(-d2 ./ (2.0 .* radius.^2));
        end

        function step(obj)
            % Advance the mesh by one sample period (time step k = 1/fs).
            ny = obj.ny; nx = obj.nx;
            U = obj.u;

            % Ghost cells implement the boundary condition. The N/S/E/W
            % stencil never reads corner ghosts, so they are left at zero.
            UP = zeros(ny + 2, nx + 2);
            UP(2:ny+1, 2:nx+1) = U;
            if strcmp(obj.boundary, 'fixed')
                % Dirichlet u=0: ghost cells already zero.
            else
                % Neumann du/dn=0, matching numpy pad mode='reflect':
                % the ghost mirrors the first *interior* cell, not the edge.
                UP(1,      2:nx+1) = U(2,    :);      % top    ghost = row 2
                UP(ny+2,   2:nx+1) = U(ny-1, :);      % bottom ghost = row ny-1
                UP(2:ny+1, 1)      = U(:,    2);      % left   ghost = col 2
                UP(2:ny+1, nx+2)   = U(:,    nx-1);   % right  ghost = col nx-1
            end

            lap = UP(3:ny+2, 2:nx+1) + UP(1:ny,   2:nx+1) ...
                + UP(2:ny+1, 3:nx+2) + UP(2:ny+1, 1:nx) ...
                - 4.0 .* UP(2:ny+1, 2:nx+1);

            u_next = obj.a0 .* (2.0 .* U - obj.sigk1 .* obj.u1 ...
                                + obj.gamma2 .* lap);
            obj.u1 = U;
            obj.u  = u_next;
        end

        function vals = sample(obj, nodes)
            % Return displacement at a list of [row, col] pickup nodes
            % (1-based MATLAB indices), as a column vector.
            n = size(nodes, 1);
            vals = zeros(n, 1);
            for idx = 1:n
                vals(idx) = obj.u(nodes(idx, 1), nodes(idx, 2));
            end
        end
    end
end
