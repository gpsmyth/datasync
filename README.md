# datasync setup

## Pre-requisites

- Setting up `versions,tf`, `providers.tf`, `variables.tf` and `locals.tf`
- Future iterations will productise this code setup

## Option choosen s3-to-s3 (no agent required)

- DataSync supports **S3 → S3** transfers entirely within AWS, with no agent to deploy. This is the best way to learn the core concepts for almost nothing.

### Overview Process

1. Create two buckets (e.g. `my-source-bucket-xyz`, `my-dest-bucket-xyz`), ideally in the same region.
1. Harden the buckets
1. Setup IAM
1. Upload ~50-100 small files (a folder of text files, some photos, or generated dummy data).
1. Create **DataSync locations** for source and destination (it will create or ask for an IAM role).
1. Create a task and run it.
1. Experiment with:
    - Include/exclude filters (e.g. only `*.jpg`)
    - **Transfer modes:** “changed data only” vs “all data”
    - Verification options (verify only transferred data vs. entire destination)
    - **Overwrite and deletion behavior** (what happens to files removed from source)
    - **CloudWatch logging** to see per-file results
    - **Task schedules** and re-running to see incremental behavior
1. Modify some source files, add new ones, delete some, and re-run to watch how DataSync handles each case.
