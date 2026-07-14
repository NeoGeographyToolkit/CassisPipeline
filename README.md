# CassisPipeline

CaSSIS (Colour and Stereo Surface Imaging System) is the pushframe stereo
imager on the ExoMars Trace Gas Orbiter.

This repository holds all the scripts and a full sample of input and output data
that allow for precise replication of the process of turning CaSSIS framelet
images into a digital terrain model (DEM) that is registered against a prior CTX
terrain. The processing uses the NASA Ames Stereo Pipeline (ASP).

## Status

This project is being assembled. Some pieces are not yet public:

- **ALE CaSSIS support is not released yet.** Initial camera generation needs a
  build of USGS ALE from latest source. Stock ALE releases cannot produce CaSSIS
  camera models. See [Dependencies](#dependencies). (not ready)
- **Reference data tarball for the Jezero example is not built yet.** It will be
  attached as a GitHub release asset. See [Reference data](#reference-data). (not ready)
- **Background documentation page is not published yet.** It will live at
  https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html (not ready).
  Until then, see the `docs/examples/cassis.rst` source in the ASP repository.

## Background

The methodology, results, and validation against CTX are described in the ASP
documentation page for CaSSIS (link above, not live yet).

## How the pipeline is organized

The pipeline runs as numbered, resumable stages driven by a single master
script, `cassis_process.sh`. The stages fall into three tiers by what they need.

**Tier 1, acquisition (run once per site).** Download the calibrated framelet
images from the ESA Planetary Science Archive, download the published vendor
CaSSIS DEM, ingest to ISIS cubes with `tgocassis2isis`, and generate an initial
CSM camera per framelet with ALE. Needs network access and SPICE kernels.

**Tier 2, preparation (light compute, needs kernels).** Build the CTX reference
DEM for the site from the USGS Astrogeology STAC catalog, build and align a
linescan DEM to CTX, split into per-framelet frame cameras, and refit a single
frozen lens distortion. Runs on a workstation with ISIS and kernels.

**Tier 3, heavy compute.** Transplant the refit lens and pose onto the cameras,
compute dense interest-point matches, then run bundle adjustment, pairwise
stereo, blending, and registration to CTX. This is the compute-heavy stage and
is meant for a cluster (for example a PBS/qsub batch node).

Because Tier 1 and 2 need kernels and network while Tier 3 is heavy compute, a
full from-scratch run is naturally **two invocations**: the prep stages on a
kernel-equipped workstation, then the heavy stages as a batch job.

### Stages

| Stage | What it does | Where |
|-------|--------------|-------|
| 0 | CTX reference DEM build | prep |
| 1 | linescan DEM | prep (needs kernels) |
| 2 | align linescan DEM to CTX | prep |
| 3 | split into frame cameras | prep |
| 4 | refit lens to a transverse distortion | prep |
| 5 | transplant lens and refit pose | heavy |
| 6 | dense matches | heavy |
| 7 | bundle adjust, stereo, blend, register (pass 1) | heavy |
| 8 | optional second pass | heavy (optional) |

The delivered product is the pass-1 DEM. The second pass mainly re-ties the
weakly-constrained framelets at the ends of each strip and gives limited extra
payoff, so it is optional and off by default.

## Repository layout

```
bin/            the pipeline scripts (put this on your PATH)
config/         example configuration files (copy these to your work dir and edit)
docs/           notes and pointers (tbd)
README.md
LICENSE
```

Scripts live in `bin/`. Data and configuration live in a separate user **work
directory**, never in this repository. This repo ships code only.

## Dependencies

- **Ames Stereo Pipeline (ASP), a recent build.** The pipeline uses options that
  are only in current builds, such as `cam_gen --csm-refit-pose` and
  `--distortion-type transverse`, `parallel_stereo --num-matches-from-disparity`
  and `--mapproj-geolocation-uncertainty`, and `point2dem
  --max-valid-triangulation-error`. Use the latest daily build or release from
  https://github.com/NeoGeographyToolkit/StereoPipeline/releases . The ASP
  distribution also bundles GNU parallel, which the pipeline uses.
- **USGS ALE, built from latest source.** Tier 1 camera generation reads the
  CaSSIS pose and lens distortion through ALE. CaSSIS driver support is in ALE
  source but **is not in any released ALE version yet**, so ALE must be built
  from the latest master of https://github.com/DOI-USGS/ale . Stock ALE will not
  produce CaSSIS camera models. (not ready)
- **ISIS and CaSSIS SPICE kernels**, on the acquisition and prep side, for
  `tgocassis2isis` and ALE.
- **Python** with numpy and GDAL, for the pairing and evaluation helpers.
- **GNU parallel** (bundled with ASP) for the parallel pairwise stereo.

## Environment

> Draft. The exact env contract is being finalized (the scripts still set some
> paths internally). The recommended setup is below.

Activate a conda environment that provides ASP together with its GDAL, PROJ, and
ISIS stack (for example the conda-forge `stereo-pipeline` package). Activation
sets `PROJ_DATA`, `GDAL_DATA`, and `ISISROOT` for you, so the tools can find
`proj.db` and the projection data. Then prepend the pipeline `bin/` to your PATH:

```bash
conda activate <your-asp-env>
export PATH=/path/to/CassisPipeline/bin:$PATH
```

If instead you use a packaged ASP tarball (not conda), point `PROJ_DATA` and
`GDAL_DATA` at its `share/proj` and set `ISISROOT` to its root yourself, then put
both the pipeline `bin/` and the ASP `bin/` on your PATH.

A `proj.db` not found error is the usual sign that the environment was not
activated (or a stale `PROJ_DATA` is set).

## Configuration

The pipeline is driven by two configuration files that live in your work
directory, not in this repository. Example copies are in `config/`.

- `cassis_recipe.conf` holds the shared recipe constants that are the same for
  every site (grid resolutions, bundle-adjustment uncertainties, the frozen lens
  coefficients, dense-match settings). You normally do not edit this.
- `cassis_site_<nick>.conf` holds the per-site data paths (the pair directory,
  the CTX reference DEM and its blurred drape, the aligned linescan DEM, the
  start camera directory, and the left and right look ids).

**Setting up a work directory (spelled out, review each step):**

1. Choose a work directory. All data paths in the site config are relative to it.
2. Copy `config/cassis_recipe.conf` and one `config/cassis_site_<nick>.conf` into
   the work directory.
3. **Edit every path in the site config to point at your data.** These are
   literal paths relative to the work directory. Do not leave the example values.
   Inspect each one and confirm the file it names actually exists. A wrong or
   stale path here fails late and wastes a batch job.
4. Leave `cassis_recipe.conf` as shipped unless you have a specific reason to
   change a constant. Any change should carry a one-line rationale comment.
5. Set up your environment and PATH (see the Environment section above), then run
   from the work directory. The full sequence, repeated here so it is self-contained:

   ```bash
   conda activate <your-asp-env>
   export PATH=/path/to/CassisPipeline/bin:/path/to/StereoPipeline/bin:$PATH
   cd /path/to/workdir
   cassis_process.sh cassis_site_<nick>.conf <fromStage> <toStage> <tagBase> <workdir>
   ```

(How exactly the config is copied and how each path is verified is worth a
careful worked example. tbd, to be filled in with the Jezero reference run.)

## Running the pipeline

A full from-scratch run is two invocations, prep then heavy:

```bash
# On a workstation with ISIS and CaSSIS kernels (prep, stages 0 to 4):
cassis_process.sh cassis_site_<nick>.conf 0 4 <tagBase> <workdir>

# On a compute node (heavy, stages 5 to 7):
cassis_process.sh cassis_site_<nick>.conf 5 7 <tagBase> <workdir>
```

If a site's prep outputs are already on disk, run only the heavy stages. Each
stage skips cheaply if its output already exists, so a failure at stage k
resumes at stage k, not from the beginning.

The final DEM is written under the pair directory in the work directory. It is
compared to the CTX reference with `geodiff` for the vertical difference and by
hillshade image correlation for the horizontal registration.

## Reference data

To let a user run and verify the pipeline without redoing acquisition, a
reference dataset for one site (Jezero) will be provided: the framelet cubes and
initial cameras, the vendor DEM, the CTX reference, the aligned linescan DEM, the
transplant cameras, the dense matches, and the final DEM with its cameras.
Intermediate stereo and bundle-adjustment scratch is excluded (large and
regenerable).

Because GitHub only hosts binaries as release assets, this dataset will be
attached to a GitHub release of this repository, and linked from here. (not ready)

## License

Apache License 2.0. See `LICENSE`.
