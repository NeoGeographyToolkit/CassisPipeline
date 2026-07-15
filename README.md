# CassisPipeline

CaSSIS (Colour and Stereo Surface Imaging System) is the pushframe stereo
imager on the ExoMars Trace Gas Orbiter.

This repository holds the scripts, and a full sample of input and output data,
that allow precise replication of the process of turning CaSSIS framelet images
into a digital terrain model (DEM) registered against existing CTX terrain. The
processing uses the NASA Ames Stereo Pipeline (ASP).

## Status

This project is being assembled. Some pieces are not yet public:

- **ALE CaSSIS support is not released yet.** Initial camera generation needs a
  build of USGS ALE from latest source. Stock ALE releases cannot produce CaSSIS
  camera models. See Dependencies below. (not ready)
- **Background documentation page is not published yet.** It will live at
  https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html (not ready).
  Until then, see the docs/examples/cassis.rst source in the ASP repository.

## Background

The methodology, results, and validation against CTX are described in the ASP
documentation page for CaSSIS (link above, not live yet).

## How the pipeline is organized

The pipeline runs as numbered, resumable stages driven by a single master script,
cassis_process.sh. The stages fall into three tiers by what they need.

**Tier 1, acquisition (run once per site).** Download the calibrated framelet
images from the ESA Planetary Science Archive, download the published CaSSIS DEM,
ingest to ISIS cubes with tgocassis2isis, and generate an initial CSM camera per
framelet with ALE. Needs network access and SPICE kernels.

**Tier 2, preparation (light compute, needs kernels).** Build the CTX reference
DEM for the site from the USGS Astrogeology STAC catalog, build and align a
linescan DEM to CTX, split into per-framelet frame cameras, and refit a single
frozen lens distortion. Runs on a workstation with ISIS and kernels.

**Tier 3, heavy compute.** Apply the corrected lens distortion and refit the
pose, compute dense interest-point matches, then run bundle adjustment, pairwise
stereo, blending, and registration to CTX. This is the compute-heavy stage and is
meant for a cluster, for example a PBS or qsub batch node.

Because Tiers 1 and 2 need kernels and network while Tier 3 is heavy compute, a
from-scratch run splits in two: the preparation on a kernel-equipped workstation
(currently run by hand, see below), then the heavy stages as a batch job.

### Stages

| Stage | What it does | Where |
|-------|--------------|-------|
| 0 | CTX reference DEM build | prep |
| 1 | linescan DEM | prep (needs kernels) |
| 2 | align linescan DEM to CTX | prep |
| 3 | split into frame cameras | prep |
| 4 | refit lens to a transverse distortion | prep |
| 5 | apply corrected lens, refit pose | heavy |
| 6 | dense matches | heavy |
| 7 | bundle adjust, stereo, blend, register (pass 1) | heavy |
| 8 | optional second pass | heavy (optional) |

The delivered product is the pass-1 DEM. The second pass mainly re-ties the
weakly-constrained framelets at the ends of each strip and gives limited extra
payoff, so it is optional and off by default.

## Repository layout

```
bin/       the pipeline scripts (put this on your PATH)
config/    example configuration files (copy these to your work dir and edit)
README.md
LICENSE
```

Scripts live in bin. Data and configuration live in a separate user work
directory, never in this repository. This repo ships code only.

## Dependencies

- **Ames Stereo Pipeline (ASP), a recent build.** The pipeline uses options that
  are only in current builds, such as cam_gen with csm-refit-pose and
  distortion-type transverse, parallel_stereo with num-matches-from-disparity and
  mapproj-geolocation-uncertainty, and point2dem with max-valid-triangulation-error.
  Use the latest daily build or release from
  https://github.com/NeoGeographyToolkit/StereoPipeline/releases . The ASP
  distribution also bundles GNU parallel, which the pipeline uses.
- **USGS ALE, built from latest source.** Tier 1 camera generation reads the
  CaSSIS pose and lens distortion through ALE. CaSSIS driver support is in ALE
  source but is not in any released ALE version yet, so ALE must be built from the
  latest master of https://github.com/DOI-USGS/ale . Stock ALE will not produce
  CaSSIS camera models. (not ready)
- **ISIS and CaSSIS SPICE kernels**, on the acquisition and prep side, for
  tgocassis2isis and ALE.
- **Python** with numpy and GDAL, for the pairing and evaluation helpers.
- **GNU parallel** (bundled with ASP) for the parallel pairwise stereo.

## Environment

The pipeline scripts do not set up any environment themselves, and do not run
conda activate or hardcode any paths, since those differ from machine to machine.
They assume the ASP and ISIS tools are on your PATH, and that the projection and
ISIS environment (PROJ_DATA, GDAL_DATA, ISISROOT) is already in place. Set this up
in one of two ways.

Recommended: activate a conda environment that provides ASP with its GDAL, PROJ,
and ISIS stack, for example the conda-forge stereo-pipeline package. Activation
sets PROJ_DATA, GDAL_DATA, and ISISROOT for you. Then prepend the pipeline bin to
your PATH:

```bash
conda activate <your-asp-env>
export PATH=/path/to/CassisPipeline/bin:$PATH
```

Alternatively, use a packaged ASP release. Its tool wrappers set ISISROOT and the
projection data themselves, so you only add the ASP bin and the pipeline bin to
your PATH:

```bash
export PATH=/path/to/CassisPipeline/bin:/path/to/StereoPipeline/bin:$PATH
```

A proj.db not found error is the usual sign that the environment was not
activated, or that a stale PROJ_DATA points at a location that no longer exists.

## Configuration

This is the part that needs the most care. Because the scripts are generic, the
burden is on you to tell the pipeline where your data is. That is done entirely
through two configuration files. They live in your work directory, not in this
repository. Example copies are in the config directory.

- cassis_common.conf holds the shared recipe constants that are the same for every
  site: grid resolutions, bundle-adjustment uncertainties, the frozen lens
  coefficients, and dense-match settings. You normally do not edit this.
- cassis_<nick>_site.conf holds the per-site data paths: the pair directory, the
  CTX reference DEM and its blurred drape, the aligned linescan DEM, the start
  camera directory, and the left and right look identifiers.

The work directory is the anchor for everything. You run the pipeline from it, and
it is passed as the last argument to every script, which changes into it before
doing any work.

**Paths in the config.** Every path in the site config is interpreted relative to
the work directory, unless it is written as an absolute path. So for each entry
you have two choices:

- a path relative to the work directory (for example
  oxia_planum/MY34_003806_019 and below), if your data lives under the work
  directory, or
- an absolute path (for example /data/cassis/oxia1 and below), if it lives
  elsewhere.

Both work. What you must not do is leave the example values in place, since they
point at data that is not yours.

**Setting up a work directory (review each step):**

1. Choose a work directory. You will run the pipeline from here.
2. Copy cassis_common.conf and one cassis_<nick>_site.conf from the config
   directory into the work directory.
3. Edit every path in the site config to point at your data, either relative to
   the work directory or absolute. Inspect each one and confirm the file it names
   actually exists. A wrong or stale path here fails late and can waste a long
   batch job.
4. Leave cassis_common.conf as shipped unless you have a specific reason to change
   a constant, in which case add a one-line rationale comment. The frozen lens
   coefficients are a global CaSSIS instrument constant, reused as is for every
   site, so you do not refit them per site.
5. Set up your environment (see above), then run from the work directory.

## Running the pipeline

The pipeline runs in numbered stages. Stages 0 to 4 are preparation: build the CTX
reference, the linescan DEM, the frame cameras, and the distortion refit. Stages 5
to 7 are the compute-heavy part: apply the corrected cameras, dense matches, then
bundle adjustment, stereo, blending, and registration. The delivered DEM is the
stage-7 result.

The supported path today is to start from a prepared work directory, for example
the reference dataset, and run the heavy stages. Set up the environment, then from
the work directory:

```bash
conda activate <your-asp-env>
export PATH=/path/to/CassisPipeline/bin:$PATH
cd /path/to/workdir

# heavy stages (5 to 7):
cassis_process.sh cassis_<nick>_site.conf 5 7 cpass /path/to/workdir
```

Each stage skips cheaply if its output already exists, so a failure at stage k
resumes at stage k. If dense matches are not present, start at stage 6, which
generates them.

On a PBS or qsub cluster, for example NASA Pleiades, submit the heavy stages as a
batch job. Adapt the queue, account, node model, core count, and walltime to your
system:

```bash
conda activate <your-asp-env>
qsub -V -N cassis -l select=1:ncpus=28 -l walltime=6:00:00 -j oe -o /dev/null -- \
  /path/to/CassisPipeline/bin/cassis_process.sh \
  cassis_<nick>_site.conf 5 7 cpass /path/to/workdir
```

The -V flag is important. By default PBS starts the job with a clean environment,
so the tools you activated would not be found on the compute node. The -V flag
exports your current environment (PATH, PROJ_DATA, ISISROOT, and the rest) to the
job. Alternatively, set the environment up in a job prologue or your shell profile
on the compute node. The worker itself changes into the work directory and writes
its own log there.

### Preparation stages (from scratch)

Running from scratch, with no prepared work directory, means building the
preparation inputs (stages 0 to 4) on a workstation that has ISIS and the CaSSIS
SPICE kernels. This part is not yet automated end to end. Running cassis_process.sh
with stages 0 to 4 prints the sequence of preparation steps and the script for
each, but does not execute them. Run those prep scripts (cassis_ctx_build.sh,
cassis_linescan_dem.sh, align_linescan_to_ctx.sh, linescan2babyframes.sh,
refit_transverse.sh) by hand for now. Once their outputs are on disk and the site
config points at them, the heavy stages above run as shown.

The final DEM is written under the pair directory in the work directory. It is
compared to the CTX reference with geodiff for the vertical difference, and by
hillshade image correlation for the horizontal registration.

## Reference data

To let a user run and verify the pipeline without redoing acquisition, a reference
dataset for one site (Jezero) is provided: the framelet cubes and original
cameras, the registered and distortion-corrected cameras, the coarse linescan DEM
aligned to CTX, the CTX reference and drape, the site configuration, and the
final DEM with its comparison products (elevation difference to CTX and the two
disparity bands). Intermediate stereo and bundle-adjustment scratch, and the dense
matches, are excluded, since they are large and regenerated.

Because GitHub only hosts binaries as release assets, this dataset is attached to a
GitHub release of this repository. Download it from the [Jezero reference dataset
release](https://github.com/NeoGeographyToolkit/CassisPipeline/releases/tag/jezero-reference),
unpack it, and run the heavy stages from the unpacked directory.

## License

Apache License 2.0. See the LICENSE file.
