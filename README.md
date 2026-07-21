# CassisPipeline

CaSSIS (Colour and Stereo Surface Imaging System) is the pushframe stereo
imager on the ExoMars Trace Gas Orbiter.

This repository provides a set of scripts and sample data that allow end-to-end
replication of the process for turning CaSSIS framelet images into a digital
terrain model (DEM) registered against an existing CTX terrain. The processing
uses the NASA Ames Stereo Pipeline (ASP).

The methodology, results, and validation against CTX are described in the [ASP
documentation page for
CaSSIS](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html).

## How the pipeline is organized

The work splits into two tiers.

**Tier 1, data ingestion.** Fetch the calibrated framelet images from the ESA
Planetary Science Archive, download the published CaSSIS DEM, download the SPICE
kernels, ingest the framelets to ISIS cubes, generate a CSM camera per framelet,
build the CTX reference DEM for the site, and make the blurred low-resolution
mapproj DEM from it. These steps need network access and careful inspection.

**Tier 2, data processing.** This step is automated and creates the registered
CaSSIS DEM. They are usually run on a remote multi-core machine.

## Repository layout

```
bin/       the pipeline scripts
config/    sample configuration files
README.md
LICENSE
```

Add the bin directory to the PATH.

## Reference data

A reference [Jezero site dataset](https://github.com/NeoGeographyToolkit/CassisPipeline/releases/tag/jezero-reference) is provided.

It has the site configuration, the framelet cubes, the original CSM cameras,
the registered and distortion-corrected cameras, the CTX reference DEM, the
coarser CTX mapprojection DEM, the preliminary CaSSIS linescan DEM aligned to
CTX, and the final produced CaSSIS DEM with its evaluation products.
Intermediate stereo, bundle-adjustment, and dense matches data are excluded,
since they are large and can be regenerated.

Extract it in the current directory.

Each command below will be practiced on it. The commands will exit quickly if
the outputs they are supposed to create already exist.

A site's inputs are specified in its config file, which the pipeline treats as
shell variables (*inputCassisDir*, *Llook*, *Rlook*, *refDem*, *mapprojDem*). See
Configuration below. For the sample commands below, source the Jezero config so
the same variables are available in the shell:

```bash
source cassis_jezero.conf
```

Here is the contents of this file. We will use these as shell variables below.

```bash
inputCassisDir=data/jezero/MY36_016378_162           # any dir holding the two looks' cubs
Llook=838849161                                      # left look id (ESA)
Rlook=838849162                                      # right look id
refDem=ref/jezero_ctx/jezero_ctx_18m.tif             # CTX reference DEM
mapprojDem=ref/jezero_ctx/jezero_ctx_18m_blur5.tif   # blurred CTX DEM
```

## Tier 1: data ingestion

Run on a local machine, with network access and inspection. Each step below is
its own small tool. Tier 1 produces the inputs the site config names: the
framelet cubs, the cameras, the reference CTX DEM, and its lower-resolution
version for mapprojection.

### Download and create the cube files

This step downloads the framelets, and ingests them to ISIS cubes. It needs an
ISIS environment. Set up the
[ISIS environment](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-isis-env)
described in the ASP documentation, then activate it and set ISISROOT (the ISIS
installation, its conda prefix) and ISISDATA (the ISIS data tree, which holds
the TGO/CaSSIS kernels).

Fetch the calibrated PAN framelets for both looks (framelet collections) from
the ESA PSA, into *inputCassisDir* (the fetch groups them into an L1 and an L2
subdirectory, named by look id, but the pipeline later finds each look by its id
in the cube filenames, so any layout works) ([Fetching the
framelets](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-fetch)):

Example for the Jezero site:

```bash
cassis_fetch_pair.sh 16378 $Llook $Rlook $inputCassisDir
```

Here, 16378 is the orbit number, the middle field of the observation id
MY36_016378_162. The observation id and its two look ids (*Llook* and *Rlook*) come
from the ESA Planetary Science Archive when selecting a CaSSIS stereo pair.

Download the SPICE kernels
([Downloading the SPICE kernels](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-kernels)).

Ingest each framelet to an ISIS cube ([Ingesting to ISIS
cubes](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-ingest)),
both in the ISIS environment. Example for the Jezero site:

```bash
conda activate isis10
export ISISROOT=$CONDA_PREFIX ISISDATA=/path/to/isisdata   # ISIS install + data tree
cassis_ingest_cubes.sh $inputCassisDir
```

### Create the CSM cameras

This step creates a CSM camera per cube with ALE. It needs the CaSSIS-capable ALE
and USGSCSM environment, described under
[Creating the CaSSIS CSM cameras](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-csm)
in the ASP documentation. Set it up and activate it. This environment also
provides gdal, numpy, and scipy, so it is reused by the processing stages below.

Example for the Jezero site:

```bash
conda activate usgscsm_cassis
export ISISDATA=/path/to/isisdata       # ISIS data directory
export ALESPICEROOT=$ISISDATA           # ALE metakernel directory
cassis_make_cameras.sh $inputCassisDir
```

The camera step needs ISISDATA (the ISIS data tree) and ALESPICEROOT (the ALE
SPICE root, where *isd_generate* finds the CaSSIS metakernels; no *spiceinit* is
run). These are usually set to the same value.

Both ingest and camera scripts scan the per-look subdirectories under the given
data root and are idempotent, so a re-run only fills in what is missing.

Do not mix the two environments.

Preparing the prior CaSSIS DEM used only for comparison is at
[Prior CaSSIS DEM](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-published-dem).

The prior CaSSIS DEM is aligned to the CTX with the same hillshade correlation
approach used later for the CaSSIS images, described at
[Alignment of prior CaSSIS DEMs to CTX](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-prior-align).

### Build the CTX reference DEM and the blurred mapproj DEM

Assemble the CTX reference DEM (*refDem*) for the site from existing CTX DEMs, and
make the low-resolution blurred mapproj DEM (*mapprojDem*) from it. See the
[documentation](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-ctx-ref).

```bash
cassis_ctx_build.sh VENDOR_DTM LAT0 LON0 OUTDIR TAG
```

See the script header for the arguments. LAT0 and LON0 are the site center; for
Jezero they are near latitude 18.4, longitude 77.5.

This step needs attention, as some sites may lack good prior CTX coverage. Check
that both the reference DEM and the mapproj DEM were produced, then set *refDem*
and *mapprojDem* in the site config.

*cassis_ctx_build.sh* produces both the reference DEM and the blurred mapproj
DEM. See the ASP [Preparation of reference CTX
DEM](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-ctx-ref).

The Jezero sample has these two products.

## Tier 2: data processing

The numbered stages (1 through 8) run on the Tier 1 inputs. Two things must be in
place first.

First, a recent ASP release is needed, from 2026/7 or later, from the [releases
page](https://github.com/NeoGeographyToolkit/StereoPipeline/releases). Such a
recent build has the CaSSIS camera support.

Second, the *usgscsm_cassis* environment from the camera step above should be
activated. It provides gdal and proj. Activate it, and put the pipeline and ASP on
the PATH:

```bash
conda activate usgscsm_cassis
export PATH=/path/to/CassisPipeline/bin:/path/to/StereoPipeline/bin:$PATH
```

Each script also checks up front that the environment is active (CONDA_PREFIX
set) and that the tools it needs are on PATH. Camera generation uses the
environment's own *isd_generate*, via CONDA_PREFIX.

### Configuration

The scripts are generic; the pipeline learns about the data through two files,
which live in the work directory, not in this repository. Example copies
are in the config directory. Both are sourced as shell variables.

The config directory ships a ready per-site config for every site in the ASP
documentation: *cassis_jezero.conf*, *cassis_ox1.conf*, *cassis_ox2.conf*,
*cassis_gusev.conf*, and *cassis_004756.conf*, plus the shared
*cassis_common.conf*. Copy the pair you need into the work directory.

- *cassis_common.conf* holds the shared recipe constants (grid resolutions,
  bundle-adjustment uncertainties, the optimized and fixed lens coefficients,
  dense-match settings). It normally does not need editing. The lens coefficients
  are a global CaSSIS instrument constant, reused as is for every site.
- *cassis_siteName.conf* (for example *cassis_jezero.conf*) holds only the per-site
  inputs, listed above under Reference data: *inputCassisDir*, *Llook*, *Rlook*, *refDem*,
  and *mapprojDem*. The two looks are found by their id in the cube filenames, so
  *inputCassisDir* can be any directory that holds them. The output directory is not
  in the config (it changes per run); it is passed on the command line (see Running).

Every path in the site config is relative to the work directory unless it is
absolute. Copy the two sample files into the work directory, edit every path to
point at the data, and confirm each named file exists. The pipeline also checks
this up front and fails fast, so a wrong path does not waste a long batch job. The
Jezero sample already ships an edited *cassis_jezero.conf*, so for the sample there
is nothing to change.

### Running

With the Tier 1 inputs in place (cubs, cameras, *refDem*, *mapprojDem*), the
master script runs the whole processing chain, stages 1 through 8:

```bash
cassis_process.sh cassis_siteName.conf 1 8 outDir /path/to/workdir
```

The five arguments are the site config, the first and last stage to run (1 to 8),
the output directory, and the work directory. All outputs go under outDir, which
can be any path and changes per run. Reuse an outDir to resume (each stage skips
outputs that already exist); use a fresh outDir for a clean run. To run or inspect
one stage at a time, set the same number for both, for example *1 1*, then *2 2*.

Each stage is also documented on its own below, so a stage can be run or inspected
individually. The quickest way to try the pipeline without any preparation is to
start from the provided reference dataset (see Reference data), which ships the
cubes, cameras, and CTX already done, so only the processing stages need running.
The CTX reference DEM and the blurred mapproj DEM are built in Tier 1 (see Build
the CTX reference DEM and the blurred mapproj DEM), not here.

### Stage 1, linescan DEM

Merges each CaSSIS look into a single image, creates a linescan camera, and
makes a first DEM, aligned to the coarse CTX reference whose grid and projection
drive every output. Needs the framelet cubes and cameras from ingestion.

Example for the Jezero site, from inside the unpacked directory:

```bash
cassis_linescan_dem.sh cassis_jezero.conf jezero_out $(pwd)
```

Check that the linescan DEM was produced under the work directory. Documented at
[Initial registration](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-init-reg).

### Stage 2, align linescan DEM to CTX

Carries the alignment transform found in stage 1 onto the tied linescan cameras,
producing the CTX-aligned linescan camera states.

Example for the Jezero site:

```bash
cassis_align_cams.sh cassis_jezero.conf jezero_out $(pwd)
```

It finds the stage-1 transform and writes the aligned camera states under
*outDir*/linescan/linescan_dem/cams_aligned/. This and stage 3 consume stage-1
and stage-2 intermediates, which the sample does not ship (they are large and
regenerated), so they run only in a from-scratch pass; starting from the sample
the run skips straight to stage 5 with the provided cameras. Documented at
[Initial registration](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-init-reg).

### Stage 3, split into frame cameras

Splits the registered linescan cameras back into per-framelet frame cameras.

Example for the Jezero site (both looks in one call):

```bash
linescan2framelets.sh cassis_jezero.conf jezero_out $(pwd)
```

Check that a frame camera was written per framelet. Documented at
[Initial registration](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-init-reg).

### Stage 4, refit the lens distortion

Refits a single optimized and fixed transverse-distortion model and sets it on
the cameras.

Example for the Jezero site (both looks in one call):

```bash
refit_transverse.sh cassis_jezero.conf jezero_out $(pwd)
```

Check the registered, distortion-corrected cameras. Documented at
[Distortion refit](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-refit).

### Stages 5 to 8, run as one batch job

These are meant to be run together as one batch job, not one at a time. On a PBS or qsub cluster, for example NASA Pleiades,
submit them as a job and adapt the queue, account, node model, core count, and
walltime to the target system:

Example for the Jezero site, from inside the unpacked directory (the master prints
to the terminal and also writes its own log in the work directory):

```bash
qsub -V -N cassis -l select=1:ncpus=28 -l walltime=6:00:00 -j oe -o cassis_qsub.log -- \
  /path/to/CassisPipeline/bin/cassis_process.sh \
  cassis_jezero.conf 5 7 jezero_out $(pwd)
```

This runs through pass 1, which is the delivered DEM. To also run the optional
pass 2, set the last stage to 8 instead of 7.

The -V flag exports the activated environment (PATH, PROJ_DATA, ISISROOT, and
the rest) to the compute node, which otherwise starts clean. The worker changes
into the work directory and writes its own log there. This set of stages can also
be run several times in parallel with different output directories and
parameter choices to compare results.

The stages within this group are:

- Stage 5, apply the corrected lens distortion and refit the pose. Documented at
  [Distortion refit](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-refit).
- Stage 6, compute dense interest-point matches (*cassis_stereo.sh*). If matches
  are absent, start the run at stage 6. Documented at
  [Dense matches](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-dense-matches).
- Stage 7, pass 1: bundle adjustment, pairwise stereo, blending, and registration
  to CTX. The delivered DEM is this result. Documented at
  [Bundle adjustment](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-ba)
  and
  [Pairwise stereo and blending](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-stereo).
- Stage 8, optional pass 2. It mainly re-ties the weakly constrained framelets at
  the ends of each strip and gives limited extra payoff, so it is off by default.
  Documented at
  [Optional refinement](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-refine).

The delivered DEM is *cassis_dem_on_ctx.tif*, under the output directory, in
*outDir*/frame/pass2_stereo/ (or *pass1_stereo/* if pass 2 was not run). Beside
it are its hillshade, the geodiff to CTX, and the max-triangulation-error mosaic.
Compare the DEM to the
CTX reference with geodiff for the vertical difference and by hillshade image
correlation for the horizontal registration, as in
[Evaluation](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-eval).

## License

Apache License 2.0. See the LICENSE file.
