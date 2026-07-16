# CassisPipeline

CaSSIS (Colour and Stereo Surface Imaging System) is the pushframe stereo
imager on the ExoMars Trace Gas Orbiter.

This repository holds the scripts, and a full sample of input and output data,
that allow precise replication of the process of turning CaSSIS framelet images
into a digital terrain model (DEM) registered against existing CTX terrain. The
processing uses the NASA Ames Stereo Pipeline (ASP).

The methodology, results, and validation against CTX are described in the [ASP
documentation page for
CaSSIS](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html).
This README covers only how to invoke the pipeline. For what each step does and
why, follow the links from each stage below into that page.

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

## Dependencies

Kept short here on purpose. The exact packages and conda environments are in the
ASP CaSSIS documentation.

- **Ames Stereo Pipeline (ASP), a recent build**, from the [releases
  page](https://github.com/NeoGeographyToolkit/StereoPipeline/releases). It
  carries its own CaSSIS-capable ISIS, ALE, and USGSCSM, and bundles GNU parallel,
  so a standard ASP install can create the CaSSIS cameras and run the stereo.
- **A conda environment providing GDAL and PROJ**, for the pairing and evaluation
  helpers. See Setup below.
- **ISIS and the CaSSIS SPICE kernels**, only for acquisition and preparation. The
  two conda environments used there, one for ISIS ingestion and one for the
  CaSSIS-capable camera generation, are described in
  [ISIS environment](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-isis-env)
  and
  [Creating the CaSSIS CSM cameras](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-csm).

## Repository layout

```
bin/       the pipeline scripts (put this on your PATH)
config/    example configuration files (copy these to your work dir and edit)
README.md
LICENSE
```

Scripts live in bin. Data and configuration live in a separate user work
directory, never in this repository. This repo ships code only.

## Setup, done once

The scripts set up no environment themselves and hardcode no paths. Two things to
prepare before running any stage. This is read once and applies to every stage
below.

First, a conda environment that provides GDAL and PROJ. This is where the tools
find proj.db and the projection data. Channel priority must be flexible, as for
the ASP install.

```bash
conda config --set channel_priority flexible
conda create -n cassis-gdal -c conda-forge gdal numpy scipy
conda activate cassis-gdal
```

Second, put the ASP release and this pipeline on your PATH. ASP is a
self-contained release, downloaded and unpacked from the releases page; it is not
installed through conda, and its tool wrappers set ISISROOT for you.

```bash
export PATH=/path/to/CassisPipeline/bin:/path/to/StereoPipeline/bin:$PATH
```

A proj.db not found error is the usual sign that the GDAL conda environment is
not activated.

Third, the configuration. Because the scripts are generic, you tell the pipeline
where your data is through two files, which live in your work directory, not in
this repository. Example copies are in the config directory.

- cassis_common.conf holds the shared recipe constants (grid resolutions,
  bundle-adjustment uncertainties, the frozen lens coefficients, dense-match
  settings). You normally do not edit it. The lens coefficients are a global
  CaSSIS instrument constant, reused as is for every site.
- cassis_siteName.conf (for example cassis_jezero.conf) holds the per-site data
  paths: the pair directory, the CTX reference DEM and its blurred drape, the
  aligned linescan DEM, the start camera directory, and the left and right look
  identifiers.

Every path in the site config is interpreted relative to the work directory
unless it is absolute. Copy the two files into your work directory, edit every
path in the site config to point at your data, and confirm each file it names
exists. A wrong path fails late and can waste a long batch job. The work
directory is the anchor for everything; it is the last argument to every script,
which changes into it before doing any work.

## Running the stages

The master script can run everything end to end:

```bash
cassis_process.sh cassis_siteName.conf 0 8 runTag /path/to/workdir
```

The five arguments are the site config, the first and last stage to run, a run
tag embedded in the output directory names, and the work directory. Choose a
distinct run tag per run so separate runs do not overwrite each other. Each stage
skips cheaply if its output already exists, so a failure at stage k resumes at
stage k.

Running all stages at once is not recommended for a first run. The preparation
stages (0 to 4) need SPICE kernels, are each worth inspecting before moving on,
and a wrong config path fails late. So the stages are walked one at a time below,
each with what it does, what to check, and a link to the matching section of the
ASP documentation. The quickest way to try the pipeline is to skip the
preparation entirely and start from the provided reference dataset (see Reference
data), which already has stages 0 to 4 done.

### Stage 0, CTX reference DEM build

Assembles the CTX reference DEM and its blurred drape for the site from existing
CTX DEMs. Run on the prep host:

```bash
cassis_ctx_build.sh VENDOR_DTM LAT0 LON0 OUTDIR TAG
```

See the script header for the arguments. Check that the reference DEM and drape
were produced, then set their paths in the site config. Documented at
[Reference CTX DEM](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-ctx-ref).

### Stage 1, linescan DEM

Merges each look into a single image, creates a linescan camera, and makes a
first DEM. Needs the SPICE kernels.

```bash
cassis_linescan_dem.sh <site>
```

Check that the linescan DEM was produced under the work directory. Documented at
[Initial registration](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-init-reg).

### Stage 2, align linescan DEM to CTX

Aligns the linescan DEM to the CTX reference.

```bash
align_linescan_to_ctx.sh <pairDir> <L_strip> <L_tiestate> <R_strip> <R_tiestate> [tag]
```

Check the aligned DEM, then set its path in the site config. Documented at
[Initial registration](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-init-reg).

### Stage 3, split into frame cameras

Splits the registered linescan cameras back into per-framelet frame cameras.

```bash
linescan2babyframes.sh <pairDir> <dataDir> <sid> <aligned_linescan_state> <look L|R>
```

Check that a frame camera was written per framelet. Documented at
[Initial registration](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-init-reg).

### Stage 4, refit the lens distortion

Refits a single frozen transverse-distortion model and sets it on the cameras.

```bash
refit_transverse.sh <cam_dir> <img_dir> <out_dir> [datum]
```

Check the registered, distortion-corrected cameras. Documented at
[Distortion refit](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-refit).

### Stages 5 to 8, the heavy stages

These are the compute-intensive part and are meant to be run together as one
batch job, not one at a time. Ensure the environment is set as in Setup above.
On a PBS or qsub cluster, for example NASA Pleiades, submit them as a job and
adapt the queue, account, node model, core count, and walltime to your system:

```bash
conda activate cassis-gdal
qsub -V -N cassis -l select=1:ncpus=28 -l walltime=6:00:00 -j oe -o /dev/null -- \
  /path/to/CassisPipeline/bin/cassis_process.sh \
  cassis_siteName.conf 5 8 runTag /path/to/workdir
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

The final DEM is written under the pair directory in the work directory. Compare
it to the CTX reference with geodiff for the vertical difference and by hillshade
image correlation for the horizontal registration, as in
[Evaluation](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-eval).

## Acquisition, from scratch (once per site)

Only needed if you are not starting from a prepared work directory. Download the
framelets and kernels, ingest to ISIS cubes, and generate the initial cameras.
Each step is documented in the ASP page:
[Fetching the framelets](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-fetch),
[Downloading the SPICE kernels](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-kernels),
[Ingesting to ISIS cubes](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-ingest),
[Creating the CaSSIS CSM cameras](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-csm),
and preparing the prior CaSSIS DEM used only for comparison
([Prior CaSSIS DEM](https://stereopipeline.readthedocs.io/en/latest/examples/cassis.html#cassis-published-dem)).

## Reference data

To let you run and verify the pipeline without redoing acquisition, a reference
dataset for one site (Jezero) is provided: the framelet cubes and original
cameras, the registered and distortion-corrected cameras, the coarse linescan DEM
aligned to CTX, the CTX reference and drape, the site configuration, and the
final DEM with its comparison products. Intermediate stereo and bundle-adjustment
scratch and the dense matches are excluded, since they are large and regenerated.

Because GitHub hosts binaries only as release assets, this dataset is attached to
a GitHub release of this repository. Download it from the [Jezero reference
dataset
release](https://github.com/NeoGeographyToolkit/CassisPipeline/releases/tag/jezero-reference),
unpack it, set up the environment as in Setup, and run the heavy stages from the
unpacked directory.

## License

Apache License 2.0. See the LICENSE file.
