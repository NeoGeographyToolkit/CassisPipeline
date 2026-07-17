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

The pipeline runs as numbered, resumable stages. Apart from image and camera
ingestion, they are driven by a single master script, cassis_process.sh. The
stages fall into three tiers by what they need.

**Tier 1, acquisition.** Download the calibrated framelet images from the ESA
Planetary Science Archive, download the published CaSSIS DEM, ingest to ISIS
cubes, and generate an initial CSM camera per framelet. This needs network
access and SPICE kernels.

**Tier 2, preparation (light compute).** Build the CTX reference DEM for the
site from the USGS Astrogeology STAC catalog, build and align a preliminary
CaSSIS DEM to CTX, create bundle-adjusted and aligned cameras. This needs
network access.

**Tier 3, heavy compute.** Apply a corrected lens distortion model, compute
dense interest-point matches, then run bundle adjustment, pairwise stereo, DEM
blending, and registration to CTX. This part is meant for a multi-core machine.

Because Tiers 1 and 2 need kernels and network while Tier 3 is heavy compute, he
former should be run on a local machine, and the heavy stages should be a batch
job.

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

It has the the site configuration, the framelet cubes, the original CSM cameras,
the registered and distortion-corrected cameras, the CTX reference DEM, the
coarser CTX mapprojection DEM, the preliminary CaSSIS linescan DEM aligned to
CTX, and the final produced CaSSIS DEM with its evaluation products.
Intermediate stereo, bundle-adjustment, and dense matches data are excluded,
since they are large and can be regenerated.

Extract it in the current directory.

Each command below will be practiced on it. The commands will exit quickly if
the outputs they are supposed to create already exist.

The sample commands below use these shell variables. Set them once in your shell:

```bash
pair=jezero/MY36_016378_162      # the pair directory
data=data/$pair                  # the framelet data root
sidL=838849161; sidR=838849162   # left and right look identifiers
```

## Data ingestion

### Download and create the cube files

This step downloads the framelets and the SPICE kernels, and ingests the framelets
to ISIS cubes. It needs an ISIS environment. Set up the
[ISIS environment](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-isis-env)
described in the ASP documentation, then activate it.

Fetch the calibrated PAN framelets for both looks (framelet collections) from
the ESA PSA, into `data/<pairDir>/L1_<sidL>` and `L2_<sidR>` ([Fetching the
framelets](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-fetch)):

```bash
cassis_fetch_pair.sh <orbit> <sidL> <sidR> data/<pairDir>
```

For the Jezero sample:

```bash
cassis_fetch_pair.sh 16378 $sidL $sidR $data
```

Download the SPICE kernels
([Downloading the SPICE kernels](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-kernels)).

Ingest each framelet to an ISIS cube ([Ingesting to ISIS
cubes](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-ingest)),
both in the ISIS environment:

```bash
conda activate isis10
cassis_ingest_cubes.sh data/<pairDir>
```

For the Jezero sample:

```bash
cassis_ingest_cubes.sh $data
```

### Create the CSM cameras

This step creates a CSM camera per cube with ALE. It needs the CaSSIS-capable ALE
and USGSCSM environment, described under
[Creating the CaSSIS CSM cameras](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-csm)
in the ASP documentation. Set it up and activate it. This environment also
provides gdal, numpy, and scipy, so it is reused by the processing stages below.

```bash
conda activate usgscsm_cassis
cassis_make_cameras.sh data/<pairDir>
```

For the Jezero sample:

```bash
cassis_make_cameras.sh $data
```

Both ingest and camera scripts scan the per-look subdirectories under the given
data root and are idempotent, so a re-run only fills in what is missing. Do not mix
the two environments. Preparing the prior CaSSIS DEM used only for comparison is at
[Prior CaSSIS DEM](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-published-dem).

## Processing stages

The numbered stages run on the ingested cubes and cameras. They need two things.

First, a recent ASP release, from 2026/7 or later, from the
[releases page](https://github.com/NeoGeographyToolkit/StereoPipeline/releases).
That build is required, as it carries the CaSSIS camera support and its own ISIS.
It is a self-contained release, unpacked from the releases page, not installed
through conda; its tool wrappers set ISISROOT for you.

Second, the `usgscsm_cassis` environment from the camera step above, which provides
gdal and proj. Activate it, and put the pipeline and ASP on your PATH:

```bash
conda activate usgscsm_cassis
export PATH=/path/to/CassisPipeline/bin:/path/to/StereoPipeline/bin:$PATH
```

A proj.db not found error is the usual sign that the `usgscsm_cassis` environment
is not activated.

### Configuration

The scripts are generic, so you tell the pipeline where your data is through two
files, which live in your work directory, not in this repository. Example copies
are in the config directory.

- cassis_common.conf holds the shared recipe constants (grid resolutions,
  bundle-adjustment uncertainties, the frozen lens coefficients, dense-match
  settings). You normally do not edit it. The lens coefficients are a global
  CaSSIS instrument constant, reused as is for every site.
- cassis_siteName.conf (for example cassis_jezero.conf) holds the per-site data
  paths: the pair directory, the CTX reference DEM and the low-resolution blurred
  CTX DEM used for mapprojection, the aligned linescan DEM, the start camera
  directory, and the left and right look identifiers.

Every path in the site config is interpreted relative to the work directory
unless it is absolute. Copy the two sample files from the config directory into
your work directory, edit every path in the site config to point at your data,
and confirm each file it names exists. A wrong path fails late and can waste a
long batch job. The Jezero sample already ships an edited cassis_jezero.conf, so
for the sample there is nothing to change.

### Running

The master script can run everything end to end:

```bash
cassis_process.sh cassis_siteName.conf 0 8 runTag /path/to/workdir
```

The five arguments are the site config, the first and last stage to run, a run
tag embedded in the output directory names, and the current work directory. Choose a
distinct run tag per run so separate runs do not overwrite each other. Each stage
skips the outputs that already exist.

Running all stages at once is not recommended for a first run. Stages 0 to 4 are
each worth inspecting before moving on, and a wrong config path fails late. So the
stages are walked one at a time below, each with what it does, what to check, and a
link to the matching section of the ASP documentation. The quickest way to try the
pipeline is to skip stages 0 to 4 entirely and start from the provided reference
dataset (see Reference data), which already has them done.

### Stage 0, CTX reference DEM creation

Assembles the CTX reference DEM and the low-resolution blurred CTX DEM used for
mapprojection for the site from existing CTX DEMs. See the
[documentation](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-ctx-ref).

```bash
cassis_ctx_build.sh VENDOR_DTM LAT0 LON0 OUTDIR TAG
```

See the script header for the arguments. LAT0 and LON0 are the site center; for
Jezero they are near latitude 18.4, longitude 77.5.

This step needs special attention, as some sites may not have prior CTX DEM
coverage, or not all of it may be of good quality. Check that the reference DEM
and the mapprojection DEM were produced, then set their paths in the site config.

The Jezero sample already ships the finished `ref/jezero_ctx/*` (the CTX reference
and the mapprojection DEM), so this step is not run for it. It is only needed when
building a new site from scratch.

### Stage 1, linescan DEM

Merges each CaSSIS look into a single image, creates a linescan camera, and
makes a first DEM, aligned to the coarse CTX reference whose grid and projection
drive every output. Needs the framelet cubes and cameras from ingestion.

```bash
cassis_linescan_dem.sh <site.conf> <workdir>
```

For the Jezero sample, from inside the unpacked directory:

```bash
cassis_linescan_dem.sh cassis_jezero.conf $(pwd)
```

Check that the linescan DEM was produced under the work directory. Documented at
[Initial registration](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-init-reg).

### Stage 2, align linescan DEM to CTX

Carries the alignment transform found in stage 1 onto the tied linescan cameras,
producing the CTX-aligned linescan camera states.

```bash
cassis_align_cams.sh <site.conf> <workdir>
```

For the Jezero sample:

```bash
cassis_align_cams.sh cassis_jezero.conf $(pwd)
```

It finds the stage-1 transform and writes the aligned camera states under
`<pairDir>/linescan/linescan_dem/cams_aligned/`. This and stage 3 consume stage-1
and stage-2 intermediates, which the sample does not ship (they are large and
regenerated), so they run only in a from-scratch pass; starting from the sample
you skip straight to stage 5 with the provided cameras. Documented at
[Initial registration](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-init-reg).

### Stage 3, split into frame cameras

Splits the registered linescan cameras back into per-framelet frame cameras.

```bash
linescan2framelets.sh <site.conf> <workdir>
```

For the Jezero sample (both looks in one call):

```bash
linescan2framelets.sh cassis_jezero.conf $(pwd)
```

Check that a frame camera was written per framelet. Documented at
[Initial registration](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-init-reg).

### Stage 4, refit the lens distortion

Refits a single frozen transverse-distortion model and sets it on the cameras.

```bash
refit_transverse.sh <site.conf> <workdir>
```

For the Jezero sample (both looks in one call):

```bash
refit_transverse.sh cassis_jezero.conf $(pwd)
```

Check the registered, distortion-corrected cameras. Documented at
[Distortion refit](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-refit).

### Stages 5 to 8, the heavy stages

These are the compute-intensive part and are meant to be run together as one
batch job, not one at a time. On a PBS or qsub cluster, for example NASA Pleiades,
submit them as a job and adapt the queue, account, node model, core count, and
walltime to your system:

```bash
qsub -V -N cassis -l select=1:ncpus=28 -l walltime=6:00:00 -j oe -o cassis_qsub.log -- \
  /path/to/CassisPipeline/bin/cassis_process.sh \
  cassis_siteName.conf 5 8 runTag /path/to/workdir
```

For the Jezero sample, from inside the unpacked directory (the master prints to
the terminal and also writes its own log in the work directory):

```bash
qsub -V -N cassis -l select=1:ncpus=28 -l walltime=6:00:00 -j oe -o cassis_qsub.log -- \
  /path/to/CassisPipeline/bin/cassis_process.sh \
  cassis_jezero.conf 5 8 rerun $(pwd)
```

The -V flag exports your activated environment (PATH, PROJ_DATA, ISISROOT, and
the rest) to the compute node, which otherwise starts clean. The worker changes
into the work directory and writes its own log there. You can also run this set
of stages several times in parallel with different run tags and parameter choices
to compare results.

The stages within this group are:

- Stage 5, apply the corrected lens distortion and refit the pose. Documented at
  [Distortion refit](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-refit).
- Stage 6, compute dense interest-point matches (cassis_stereo.sh). If matches
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

The delivered DEM is `cassis_dem_on_ctx.tif`, under the pair directory in the
work directory, in `<pairDir>/frame/<runTag>_stereo/`. Beside it are its hillshade,
the geodiff to CTX, and the max-triangulation-error mosaic. Compare the DEM to the
CTX reference with geodiff for the vertical difference and by hillshade image
correlation for the horizontal registration, as in
[Evaluation](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-eval).

## License

Apache License 2.0. See the LICENSE file.
