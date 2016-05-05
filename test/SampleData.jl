module SampleData

using Celeste: Model, ElboDeriv
import Celeste: WCSUtils, Infer

import Synthetic

using Distributions
import WCS, FITSIO, DataFrames


export empty_model_params, dat_dir,
       sample_ce, perturb_params,
       sample_star_fluxes, sample_galaxy_fluxes,
       gen_sample_star_dataset, gen_sample_galaxy_dataset,
       gen_two_body_dataset, gen_three_body_dataset, gen_n_body_dataset,
       make_elbo_args

const dat_dir = joinpath(Pkg.dir("Celeste"), "test", "data")

const sample_star_fluxes = [
    4.451805E+03,1.491065E+03,2.264545E+03,2.027004E+03,1.846822E+04]
const sample_galaxy_fluxes = [
    1.377666E+01, 5.635334E+01, 1.258656E+02,
    1.884264E+02, 2.351820E+02] * 100  # 1x wasn't bright enough

# A world coordinate system where the world and pixel coordinates are the same.
const wcs_id = WCS.WCSTransform(2,
                    cd = Float64[1 0; 0 1],
                    ctype = ["none", "none"],
                    crpix = Float64[1, 1],
                    crval = Float64[1, 1]);


"""
Turn a blob and vector of catalog entries into elbo arguments
that can be used with Celeste.
"""
function make_elbo_args(images::Vector{TiledImage},
                        catalog::Vector{CatalogEntry};
                        fit_psf::Bool=false,
                        patch_radius::Float64=NaN)
    vp = Vector{Float64}[init_source(ce) for ce in catalog]
    patches, tile_source_map = Infer.get_tile_source_map(images, catalog,
                                radius_override=patch_radius)
    active_sources = collect(1:length(catalog))
    ea = ElboArgs(images, vp, tile_source_map, patches, active_sources)
    if fit_psf
        Infer.fit_object_psfs!(ea, ea.active_sources)
    end
    ea
end


function make_elbo_args(images::Vector{Image},
                        catalog::Vector{CatalogEntry};
                        tile_width::Int=20,
                        fit_psf::Bool=false,
                        patch_radius::Float64=NaN)
    tiled_images = TiledImage[TiledImage(img, tile_width=tile_width)
         for img in images]
    make_elbo_args(tiled_images, catalog; fit_psf=fit_psf,
                                patch_radius=patch_radius)
end


"""
Load a stamp into a Celeste blob.
"""
function load_stamp_blob(stamp_dir, stamp_id)
    function fetch_image(b)
        band_letter = band_letters[b]
        filename = "$stamp_dir/stamp-$band_letter-$stamp_id.fits"

        fits = FITSIO.FITS(filename)
        hdr = FITSIO.read_header(fits[1])
        original_pixels = read(fits[1])
        dn = original_pixels / hdr["CALIB"] + hdr["SKY"]
        nelec_f32 = round(dn * hdr["GAIN"])
        nelec = convert(Array{Float64}, nelec_f32)

        header_str = FITSIO.read_header(fits[1], ASCIIString)
        wcs = WCS.from_header(header_str)[1]
        close(fits)

        alphaBar = [hdr["PSF_P0"]; hdr["PSF_P1"]; hdr["PSF_P2"]]
        xiBar = [
            [hdr["PSF_P3"]  hdr["PSF_P4"]];
            [hdr["PSF_P5"]  hdr["PSF_P6"]];
            [hdr["PSF_P7"]  hdr["PSF_P8"]]]'

        tauBar = Array(Float64, 2, 2, 3)
        tauBar[:,:,1] = [[hdr["PSF_P9"] hdr["PSF_P11"]];
                         [hdr["PSF_P11"] hdr["PSF_P10"]]]
        tauBar[:,:,2] = [[hdr["PSF_P12"] hdr["PSF_P14"]];
                         [hdr["PSF_P14"] hdr["PSF_P13"]]]
        tauBar[:,:,3] = [[hdr["PSF_P15"] hdr["PSF_P17"]];
                         [hdr["PSF_P17"] hdr["PSF_P16"]]]

        psf = [PsfComponent(alphaBar[k], xiBar[:, k],
                            tauBar[:, :, k]) for k in 1:3]

        H, W = size(original_pixels)
        iota = hdr["GAIN"] / hdr["CALIB"]
        epsilon = hdr["SKY"] * hdr["CALIB"]

        run_num = round(Int, hdr["RUN"])
        camcol_num = round(Int, hdr["CAMCOL"])
        field_num = round(Int, hdr["FIELD"])

        epsilon_mat = fill(epsilon, H, W)
        iota_vec = fill(iota, H)
        empty_psf_comp = RawPSF(Array(Float64, 0, 0), 0, 0, 
                                 Array(Float64, 0, 0, 0)) 

        Image(H, W, nelec, b, wcs, psf,
              run_num, camcol_num, field_num, epsilon_mat, iota_vec,
              empty_psf_comp)
    end

    blob = map(fetch_image, 1:5)
end


function load_stamp_catalog_df(cat_dir, stamp_id, blob; match_blob=false)
    # These files are generated by
    # https://github.com/dstndstn/tractor/blob/master/projects/inference/testblob2.py
    cat_fits = FITSIO.FITS("$cat_dir/cat-$stamp_id.fits")
    num_cols = FITSIO.read_key(cat_fits[2], "TFIELDS")[1]
    ttypes = [FITSIO.read_key(cat_fits[2], "TTYPE$i")[1] for i in 1:num_cols]

    df = DataFrames.DataFrame()
    for i in 1:num_cols
        tmp_data = read(cat_fits[2], ttypes[i])
        df[symbol(ttypes[i])] = tmp_data
    end

    close(cat_fits)

    if match_blob
        camcol_matches = df[:camcol] .== blob[3].camcol_num
        run_matches = df[:run] .== blob[3].run_num
        field_matches = df[:field] .== blob[3].field_num
        df = df[camcol_matches & run_matches & field_matches, :]
    end

    df
end


"""
Load a stamp catalog.
"""
function load_stamp_catalog(cat_dir, stamp_id, blob; match_blob=false)
    df = load_stamp_catalog_df(cat_dir, stamp_id, blob,
                                    match_blob=match_blob)
    df[:objid] = [ string(s) for s=1:size(df)[1] ]

    function row_to_ce(row)
        x_y = [row[1, :ra], row[1, :dec]]
        star_fluxes = zeros(5)
        gal_fluxes = zeros(5)
        fracs_dev = [row[1, :frac_dev], 1 - row[1, :frac_dev]]
        for b in 1:length(band_letters)
            bl = band_letters[b]
            psf_col = symbol("psfflux_$bl")

            # TODO: How can there be negative fluxes?
            star_fluxes[b] = max(row[1, psf_col], 1e-6)

            dev_col = symbol("devflux_$bl")
            exp_col = symbol("expflux_$bl")
            gal_fluxes[b] += fracs_dev[1] * max(row[1, dev_col], 1e-6) +
                             fracs_dev[2] * max(row[1, exp_col], 1e-6)
        end

        fits_ab = fracs_dev[1] > .5 ? row[1, :ab_dev] : row[1, :ab_exp]
        fits_phi = fracs_dev[1] > .5 ? row[1, :phi_dev] : row[1, :phi_exp]
        fits_theta = fracs_dev[1] > .5 ? row[1, :theta_dev] : row[1,
:theta_exp]

        # tractor defines phi as -1 * the phi catalog for some reason.
        if !match_blob
            fits_phi *= -1.
        end

        re_arcsec = max(fits_theta, 1. / 30)  # re = effective radius
        re_pixel = re_arcsec / 0.396

        phi90 = 90 - fits_phi
        phi90 -= floor(phi90 / 180) * 180
        phi90 *= (pi / 180)

        CatalogEntry(x_y, row[1, :is_star], star_fluxes,
            gal_fluxes, row[1, :frac_dev], fits_ab, phi90, re_pixel,
            row[1, :objid], 0)
    end

    CatalogEntry[row_to_ce(df[i, :]) for i in 1:size(df, 1)]
end


function empty_model_params(S::Int)
    vp = [Model.init_source([ 0., 0. ]) for s in 1:S]
    ElboArgs(TiledImage[],
             vp,
             Array(Matrix{Vector{Int}}, 0),
             Array(SkyPatch, S, 0),
             collect(1:S))
end


function sample_ce(pos, is_star::Bool)
    CatalogEntry(pos, is_star, sample_star_fluxes, sample_galaxy_fluxes,
        0.1, .7, pi/4, 4., "sample", 0)
end


function perturb_params(ea) # for testing derivatives != 0
    for vs in ea.vp
        vs[ids.a] = [ 0.4, 0.6 ]
        vs[ids.u[1]] += .8
        vs[ids.u[2]] -= .7
        vs[ids.r1] -= log(10)
        vs[ids.r2] *= 25.
        vs[ids.e_dev] += 0.05
        vs[ids.e_axis] += 0.05
        vs[ids.e_angle] += pi/10
        vs[ids.e_scale] *= 1.2
        vs[ids.c1] += 0.5
        vs[ids.c2] =  1e-1
    end
end


function gen_sample_star_dataset(; perturb=true)
    srand(1)
    blob0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf")
    for b in 1:5
        blob0[b].H, blob0[b].W = 20, 23
        blob0[b].wcs = wcs_id
    end
    one_body = [sample_ce([10.1, 12.2], true),]
    blob = Synthetic.gen_blob(blob0, one_body)
    ea = make_elbo_args(blob, one_body)
    if perturb
        perturb_params(ea)
    end
    blob, ea, one_body
end


function gen_sample_galaxy_dataset(; perturb=true)
    srand(1)
    blob0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf")
    for b in 1:5
        blob0[b].H, blob0[b].W = 20, 23
        blob0[b].wcs = wcs_id
    end
    one_body = [sample_ce([8.5, 9.6], false),]
    blob = Synthetic.gen_blob(blob0, one_body)
    ea = make_elbo_args(blob, one_body)
    if perturb
        perturb_params(ea)
    end
    blob, ea, one_body
end

function gen_two_body_dataset(; perturb=true)
    # A small two-body dataset for quick unit testing.  These objects
    # will be too close to be identifiable.

    srand(1)
    blob0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf")
    for b in 1:5
        blob0[b].H, blob0[b].W = 20, 23
        blob0[b].wcs = wcs_id
    end
    two_bodies = [
        sample_ce([4.5, 3.6], false),
        sample_ce([10.1, 12.1], true)
    ]
    blob = Synthetic.gen_blob(blob0, two_bodies)
    ea = make_elbo_args(blob, two_bodies)
    if perturb
        perturb_params(ea)
    end
    blob, ea, two_bodies
end



function gen_three_body_dataset(; perturb=true)
    srand(1)
    blob0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf")
    for b in 1:5
        blob0[b].H, blob0[b].W = 112, 238
        blob0[b].wcs = wcs_id
    end
    three_bodies = [
        sample_ce([4.5, 3.6], false),
        sample_ce([60.1, 82.2], true),
        sample_ce([71.3, 100.4], false),
    ];
    blob = Synthetic.gen_blob(blob0, three_bodies);
    ea = make_elbo_args(blob, three_bodies);
    if perturb
        perturb_params(ea)
    end
    blob, ea, three_bodies
end


"""
Generate a large dataset with S randomly placed bodies and non-constant
background.
"""
function gen_n_body_dataset(
    S::Int; patch_pixel_radius=20., tile_width=50, seed=NaN)

  if !isnan(seed)
    srand(seed)
  end

  blob0 = load_stamp_blob(dat_dir, "164.4311-39.0359_2kpsf");
  img_size_h = 900
  img_size_w = 1000
  for b in 1:5
      blob0[b].H, blob0[b].W = img_size_h, img_size_w
  end

  fluxes = [4.451805E+03,1.491065E+03,2.264545E+03,2.027004E+03,1.846822E+04]

  locations = rand(2, S) .* [img_size_h, img_size_w]
  world_locations = WCSUtils.pix_to_world(blob0[3].wcs, locations)

  S_bodies = CatalogEntry[CatalogEntry(world_locations[:, s], true,
      fluxes, fluxes, 0.1, .7, pi/4, 4., string(s), s) for s in 1:S];

  blob = Synthetic.gen_blob(blob0, S_bodies);

  # Make non-constant background.
  for b=1:5
    blob[b].iota_vec = fill(blob[b].iota_vec[1], blob[b].H)
    blob[b].epsilon_mat = fill(blob[b].epsilon_mat[1], blob[b].H, blob[b].W)
  end

  world_radius_pts = WCSUtils.pix_to_world(
      blob[3].wcs, [patch_pixel_radius 0.; patch_pixel_radius 0.])
  world_radius = maxabs(world_radius_pts[:, 1] - world_radius_pts[:, 2])
  ea = make_elbo_args(
    blob, S_bodies, tile_width=tile_width, patch_radius=world_radius)

  blob, ea, S_bodies
end

end # End module
