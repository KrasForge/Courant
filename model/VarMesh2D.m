classdef VarMesh2D < handle
    % VarMesh2D  2D FDTD with spatially-varying coefficients (issue #32).
    %
    % Same explicit lossy-wave update as Mesh2D, but gamma^2, a0 and sigk1 are
    % per-node maps (ny x nx matrices) instead of scalars, so the material
    % properties vary across the mesh: a damped rim, a stiffer/faster centre,
    % a tension gradient, etc. (milestone M9). Reference-model only; the study
    % vehicle for the RTL storage/distribution cost assessment.
    %
    %   u^{n+1}(i,j) = a0(i,j) * ( 2u(i,j) - sigk1(i,j) u^{n-1}(i,j)
    %                              + gamma2(i,j) * Lap(u)(i,j) )
    %
    % built from physical maps:
    %   gamma2 = (c_map k / h).^2      per-node Courant number squared
    %   a0     = 1 ./ (1 + sigma_map k)
    %   sigk1  = 1 - sigma_map k
    %
    % Stability: the CFL bound is LOCAL — every node must satisfy
    % gamma2(i,j) <= 1/2, so the constructor checks max(gamma2(:)). Spatially
    % varying damping (sigma) is unconditionally stable; only the wave-speed map
    % is CFL-constrained.
    %
    % Uniform maps reduce this class exactly to Mesh2D (fixed boundary).
    % Handle class: step() mutates in place.

    properties
        nx
        ny
        boundary
        gamma2      % ny x nx
        a0          % ny x nx
        sigk1       % ny x nx
        u
        u1
    end

    methods
        function obj = VarMesh2D(nx, ny, fs, h, c_map, sigma_map, boundary, check_cfl)
            if nargin < 7 || isempty(boundary);  boundary  = 'fixed'; end
            if nargin < 8 || isempty(check_cfl); check_cfl = true;    end

            c_map     = expand(c_map, ny, nx);
            sigma_map = expand(sigma_map, ny, nx);

            k = 1.0 / fs;
            g2 = (c_map .* k ./ h) .^ 2;
            if check_cfl && max(g2(:)) > 0.5
                error('VarMesh2D:CFL', ...
                    ['Local CFL violated: max gamma^2 = %.4f > 0.5 at some ' ...
                     'node. Reduce the peak wave speed or increase h.'], ...
                    max(g2(:)));
            end

            obj.nx = nx;  obj.ny = ny;  obj.boundary = boundary;
            obj.gamma2 = g2;
            obj.a0     = 1.0 ./ (1.0 + sigma_map .* k);
            obj.sigk1  = 1.0 - sigma_map .* k;
            obj.u  = zeros(ny, nx);
            obj.u1 = zeros(ny, nx);
        end

        function strike(obj, si, sj, radius, amp)
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
            if strcmp(obj.boundary, 'fixed')
                % Dirichlet u=0: ghosts already zero.
            else
                UP(1,      2:nx+1) = U(2,    :);
                UP(ny+2,   2:nx+1) = U(ny-1, :);
                UP(2:ny+1, 1)      = U(:,    2);
                UP(2:ny+1, nx+2)   = U(:,    nx-1);
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
            n = size(nodes, 1);
            vals = zeros(n, 1);
            for idx = 1:n
                vals(idx) = obj.u(nodes(idx, 1), nodes(idx, 2));
            end
        end
    end
end

function M = expand(v, ny, nx)
    % Accept a scalar or a full ny x nx map.
    if isscalar(v)
        M = v .* ones(ny, nx);
    else
        if ~isequal(size(v), [ny, nx])
            error('VarMesh2D:map', 'coefficient map must be scalar or %dx%d.', ny, nx);
        end
        M = v;
    end
end
