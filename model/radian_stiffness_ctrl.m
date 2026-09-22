function [mu2, gamma2_max_eff] = radian_stiffness_ctrl(ctrl, gamma2_max)
% RADIAN_STIFFNESS_CTRL  Production #86 STIFFNESS control mapping.
%
% ctrl is the stored unsigned 8-bit value (0..255).
%   mu2 = ctrl / 4096
%
% The current RADIAN anisotropy redistributes X/Y propagation while preserving
% g2x+g2y = 2*gamma2, so the studied stiff-surface stability condition
%
%   (g2x+g2y) + 16*mu2 <= 1
%
% becomes gamma2 <= 0.5 - 8*mu2. gamma2_max_eff is also capped by the
% pre-existing gamma2_max safety ceiling.
%
% This helper mirrors src/rtl/physical_pkg.vhd.
    if nargin < 2 || isempty(gamma2_max); gamma2_max = 0.451; end
    assert(ctrl >= 0 && ctrl <= 255 && ctrl == floor(ctrl), ...
           'ctrl must be an integer in 0..255');
    mu2 = double(ctrl) / 4096.0;
    gamma2_max_eff = max(0.0, min(gamma2_max, 0.5 - 8.0 * mu2));
end
