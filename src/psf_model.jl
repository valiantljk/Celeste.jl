# The number of Gaussian components in the PSF.
const psf_K = 2


"""
A single normal component of the point spread function.
All quantities are in pixel coordinates.

Args:
  alphaBar: The scalar weight of the component.
  xiBar: The 2x1 location vector
  tauBar: The 2x2 covariance

Attributes:
  alphaBar: The scalar weight of the component.
  xiBar: The 2x1 location vector
  tauBar: The 2x2 covariance (tau_bar in the ICML paper)
  tauBarInv: The 2x2 precision
  tauBarLd: The log determinant of the covariance
"""
immutable PsfComponent
    alphaBar::Float64  # TODO: use underscore
    xiBar::Vector{Float64}
    tauBar::Matrix{Float64}

    tauBarInv::Matrix{Float64}
    tauBarLd::Float64
end

function PsfComponent(alphaBar::Float64, xiBar::Vector{Float64},
                      tauBar::Matrix{Float64})
    PsfComponent(alphaBar, xiBar, tauBar, tauBar^-1, logdet(tauBar))
end

function get_psf_width(psf::Array{PsfComponent}; width_scale=1.0)
    # A heuristic measure of the PSF width based on an anology
    # with it being a mixture of normals.    Note that it is not an actual
    # mixture of normals, and in particular that sum(alphaBar) \ne 1.

    # The PSF is not necessarily centered at (0, 0), but we want a measure
    # of its maximal width around (0, 0), not around its center.
    # Approximate this by finding the covariance of a point randomly drawn
    # from a mixture of gaussians.
    alpha_norm = sum([ psf_comp.alphaBar for psf_comp in psf ])
    cov_est = zeros(Float64, 2, 2)
    for psf_comp in psf
        cov_est +=
            psf_comp.alphaBar * (psf_comp.xiBar * psf_comp.xiBar' + psf_comp.tauBar) /
            alpha_norm
    end

    # Return the twice the sd of the most spread direction, scaled by the total
    # mass in the PSF.
    width_scale * sqrt(eigvals(cov_est)[end]) * alpha_norm
end


