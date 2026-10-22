# datasync setup

## Pre-requisites

- Setting up `versions.tf`, `providers.tf`, `variables.tf` and `locals.tf`
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

## Sample data

A local directory is used using `sample-data` - the directory usage provides the following advantages:
- You edit real files rather than HCL strings, which would use file contents hardcoded in Terraform
- `fileset("${path.module}/sample-data", "**")` picks up anything you add, so new files need no Terraform changes.
- Deleting a local file and re-applying removes it from the source bucket, which is how you simulate source-side deletes.

It's recommended to have files with content in them as empty files (e.g. using `touch`) will make the experiments less informative as:
- **Transfer stats** are uninformative. Everything shows 0 bytes, so you can’t tell whether a file was really re-copied.
- **Changes are invisible to Terraform.** The upload is keyed on `source_hash = filemd5(...)`, which hashes content. Running touch on an existing file only updates its timestamp, so Terraform sees no change and uploads nothing, which means DataSync has nothing new to detect either. To simulate a modification, you must change the content.
- **Every empty file has the same MD5.** That’s harmless, but it makes it harder to tell which file changed.

So in summary, small files with distinct content work better:

```zsh
mkdir -p sample-data/{docs,images,scratch}

echo "hello datasync"  > sample-data/docs/hcl.txt
echo "second file"     > sample-data/docs/notes.txt
head -c 2048 /dev/urandom > sample-data/images/dog.jpg   # random bytes, 2 KB
echo "temp"            > sample-data/scratch/smtg.tmp    # should be excluded by the task
```

A loop is handy if you want a larger set,

```zsh
for i in $(seq -w 1 20); do echo "note $i" > sample-data/docs/note-$i.txt; done
```

## Things to know

- **Empty directories aren’t uploaded.** S3 has no real folders, only keys with `/` in them, so a directory with no files in it produces nothing.
- **Keep the files small.** They live in my repo, and DataSync is billed per GB, so a few KB is effectively free.
- **To simulate a modification**, run `echo "changed $(date)" >> sample-data/docs/hcl.txt`, then `terraform apply`, then re-run the task. Only that file should transfer with `transfer_mode = "CHANGED"`.

## Run Order

```zsh
terraform init
terraform fmt && terraform validate
terraform plan -out tfplan
terraform apply tfplan
$(terraform output -raw start_task_command)
```

Then check that the `.tmp` files are missing from the destination and that logs appear in `/aws/datasync/s3tos3`.


## Trouble-shooting

When running `terraform apply tfplan` I got:

```zsh

│ Error: creating DataSync Location S3: operation error DataSync: CreateLocationS3, https response error StatusCode: 400, RequestID: ef22342a-b00b-442e-98e0-dc193da7b766, InvalidRequestException: Invalid IAM role, arn:aws:iam::<account_id>:role/datasync-s3-source. DataSync service was unable to perform sts:AssumeRole.
```

for both `aws_datasync_location_s3.source` and `aws_datasync_location_s3.dest`

- **A first-apply hiccup is plausible.** IAM and the CloudWatch resource policy are eventually consistent, so if `aws_datasync_task` or a location fails with an access or validation error, re-running `terraform apply` normally resolves it. My dependencies make this unlikely but not impossible.

## Why it failed, and why a retry should work

“DataSync service was unable to perform sts:AssumeRole” at this point almost always means IAM eventual consistency. The `datasync-s3-source` role was created previously and its policy also attached, and `CreateLocationS3` was called within about a second or two. At that moment, DataSync’s side of IAM may not yet have seen the new role. The two errors only appeared at the end of the output because Terraform reports failures after the other parallel work (after the 57-second lifecycle configurations) finished. The location calls themselves failed within seconds of the role being created. As further time has passed now, the roles would have propagated.

### Fix for future applies to be more reliable

The retry succeededd, the cause was `IAM` propagation, and a fresh apply or destroy and re-create could hit it again. The usual fix is a short delay between the role policies and the locations, using the `hashicorp/time` provider:

```zsh
resource "time_sleep" "iam_propagation" {
  create_duration = "30s"
  depends_on = [
    aws_iam_role_policy.source,
    aws_iam_role_policy.dest,
  ]
}
```

Then have both locations in `datasync.tf` use `depends_on = [time_sleep.iam_propagation]` in place of the role-policy dependency. I added `time` to `required_providers` and ran `terraform init`

As a note the locations in `datasync.tf` are referenced by resource `aws_datasync_location_s3` 

Note:
- `depends_on` **changes don’t alter a resource.** Terraform uses them only to order operations and doesn’t store them as attributes,

Further `terraform plan` commands showed (snippet)

```zsh
~ task_report_config {
    # (3 unchanged attributes hidden)

     - report_overrides {}
```

- **The same** `- report_overrides {}` **reappearing** means the provider is re-populating the empty block on every read. In that case the prompt will keep coming back, because there will always be a pending change. Add the `ignore_changes` block inside the aws_datasync_task resource:

```zsh
  lifecycle {
    ignore_changes = [task_report_config[0].report_overrides]
  }
```
Then `terraform plan` reported No changes, and `terraform apply` will have nothing to ask about and was performed anyway along with a subsequent plan.

If it takes the `ignore_changes` route, you may see the apply “succeed” while changing nothing real. That’s expected here, because the diff was only the provider disagreeing with an empty block.

## Limits of the sleep fix

- **It can’t be tested without recreating things.** The sleep only runs when `time_sleep` is created, and it already exists with the locations, so nothing is exercised by this plan. The real test is a fresh `terraform destroy` followed by `terraform apply`, which would show a 30-second pause before the locations are created. That’s worth doing once at the end of your experiments, and it doubles as a check that your cleanup works.
- **It won’t re-run when IAM changes.** If you later edit a role policy, the existing `time_sleep` isn’t recreated, so the pause doesn’t repeat. For a lab that’s fine. To make it re-trigger, add a `triggers` map keyed on the policy documents (for example `triggers = { source = aws_iam_role_policy.source.policy }`).
- **30 seconds is a reasonable value, not a guarantee.** IAM propagation is usually quicker, but if you ever hit the error again, raise it rather than treating it as a different problem.

## Datasync run

- Capture the execution arn
The command prints JSON containing a `TaskExecutionArn`. Saving it makes the follow-up commands easier:

```zsh
EXEC_ARN=$($(terraform output -raw start_task_command) --query TaskExecutionArn --output text)
echo $EXEC_ARN
```

Then watch it with:
```zsh
aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn $EXEC_ARN \
  --query '{Status:Status,Files:FilesTransferred,Bytes:BytesTransferred,Result:Result}'

{
    "Status": "LAUNCHING",
    "Files": 0,
    "Bytes": 0,
    "Result": null
}
```
I ran that every 10 seconds or so. Expect `Status` to move through `QUEUED`, `LAUNCHING`, `PREPARING`, `TRANSFERRING` and `VERIFYING` before ending at `SUCCESS`. With four small files, the whole thing usually takes about a minute or two, and most of that is startup overhead rather than data transfer.

e.g
```zsh
❯ aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn $EXEC_ARN \
  --query '{Status:Status,Files:FilesTransferred,Bytes:BytesTransferred,Result:Result}'
{
    "Status": "TRANSFERRING",
    "Files": 0,
    "Bytes": 0,
    "Result": {
        "PrepareDuration": 3138,
        "PrepareStatus": "PENDING",
        "TotalDuration": 7182,
        "TransferDuration": 5613,
        "TransferStatus": "PENDING",
        "VerifyDuration": 0,
        "VerifyStatus": "PENDING"
    }
}

❯ aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn $EXEC_ARN \
  --query '{Status:Status,Files:FilesTransferred,Bytes:BytesTransferred,Result:Result}'
{
    "Status": "SUCCESS",
    "Files": 3,
    "Bytes": 2075,
    "Result": {
        "PrepareDuration": 1569,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 9008,
        "TransferDuration": 7116,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 264,
        "VerifyStatus": "SUCCESS"
    }
}
```

## What a good first run looks like

- **Files.** Expect `FilesTransferred` around 3 (`hcl.txt`, `notes.txt`, `dog.jpg`) with `smtg.tmp` excluded. The count may also include directory entries depending on how DataSync reports them, so don’t be alarmed if it’s slightly different. The destination listing is the real check:
```zsh
❯   aws s3 ls s3://$(terraform output -raw dest_bucket)/ --recursive
2026-10-15 13:48:20         15 docs/hcl.txt
2026-10-15 13:48:20         12 docs/notes.txt
2026-10-15 13:48:20       2048 images/dog.jpg
```

- **Logs**
```zsh
❯ aws logs tail /aws/datasync/s3tos3 --region ap-southeast-2 --since 30m

2026-10-15T00:46:55.523000+00:00 task-00d85e7072195ae0c-exec-07f7b8aa02fced81e [INFO] Request to start task-00d85e7072195ae0c.
2026-10-15T00:48:14.389000+00:00 task-00d85e7072195ae0c-exec-07f7b8aa02fced81e [INFO] Execution exec-07f7b8aa02fced81e started.
2026-10-15T00:48:19.154000+00:00 task-00d85e7072195ae0c-exec-07f7b8aa02fced81e [NOTICE] Transferred file /docs/notes.txt, 12 bytes
2026-10-15T00:48:19.157000+00:00 task-00d85e7072195ae0c-exec-07f7b8aa02fced81e [NOTICE] Transferred file /docs/hcl.txt, 15 bytes
2026-10-15T00:48:19.179000+00:00 task-00d85e7072195ae0c-exec-07f7b8aa02fced81e [NOTICE] Transferred file /images/dog.jpg, 2048 bytes
2026-10-15T00:48:20.007000+00:00 task-00d85e7072195ae0c-exec-07f7b8aa02fced81e [NOTICE] Verified file /docs/hcl.txt, 15 bytes
2026-10-15T00:48:20.007000+00:00 task-00d85e7072195ae0c-exec-07f7b8aa02fced81e [NOTICE] Verified file /docs/notes.txt, 12 bytes
2026-10-15T00:48:20.007000+00:00 task-00d85e7072195ae0c-exec-07f7b8aa02fced81e [NOTICE] Verified file /images/dog.jpg, 2048 bytes
2026-10-15T00:48:20.495000+00:00 task-00d85e7072195ae0c-exec-07f7b8aa02fced81e [INFO] Execution exec-07f7b8aa02fced81e finished with status Success.
```
should show per-file transfer entries.

- **Reports.** Check
```zsh
❯ aws s3 ls s3://$(terraform output -raw reporting_bucket)/reports/ --recursive

2026-10-15 13:48:21       1008 reports/Detailed-Reports/task-00d85e7072195ae0c/exec-07f7b8aa02fced81e/exec-07f7b8aa02fced81e.files-transferred-v1-00001-0a55b3c5704e149e3.json
2026-10-15 13:48:21       1466 reports/Detailed-Reports/task-00d85e7072195ae0c/exec-07f7b8aa02fced81e/exec-07f7b8aa02fced81e.files-verified-v1-00001-0a55b3c5704e149e3.json
2026-10-15 13:46:56          0 reports/Summary-Reports/
2026-10-15 13:48:49       1540 reports/Summary-Reports/task-00d85e7072195ae0c/exec-07f7b8aa02fced81e/exec-07f7b8aa02fced81e.summary-v1.json
```
and allow a few minutes after `SUCCESS` before concluding they’re missing.

## Further test runs

### Simulate 20 files to transfer

```zsh
for i in $(seq -w 1 20); do echo "note $i" > sample-data/docs/note-$i.txt; done
```
- Perform `terraform apply` and enter `yes` if you've noted 20 file changes occurring
- Perform `$(terraform output -raw start_task_command)` to produce a task execution arn. 
- Progress with examaning status as followss:
```zsh
aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN" \
  --query '{Status:Status,Files:FilesTransferred,Bytes:BytesTransferred,Result:Result}'
{
    "Status": "SUCCESS",
    "Files": 20,
    "Bytes": 160,
    "Result": {
        "PrepareDuration": 1568,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 6719,
        "TransferDuration": 4549,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 521,
        "VerifyStatus": "SUCCESS"
    }
}
```

or run the full command of 
```zsh
 aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN"
```

The following parameter are noted:
- "FilesTransferred": 20,
- "BytesTransferred": 160,
- "FilesDeleted": 0,
- "FilesSkipped": 3,
- "FilesVerified": 20, 

### Simulate incremental behaviour

- Edit two files out of the previous 20 created
```zsh
echo "changed $(date)" >> sample-data/docs/note-03.txt
echo "changed $(date)" >> sample-data/docs/note-07.txt
terraform apply
$(terraform output -raw start_task_command)
```

As you can see, two files were transferred
```zsh
❯ aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN" \
  --query '{Status:Status,Files:FilesTransferred,Bytes:BytesTransferred,Result:Result}'
{
    "Status": "SUCCESS",
    "Files": 2,
    "Bytes": 92,
    "Result": {
        "PrepareDuration": 1539,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 3888,
        "TransferDuration": 2070,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 234,
        "VerifyStatus": "SUCCESS"
    }
}
```
- EXEC_ARN variable was captured prior

### Perform Deletions

1. `rm sample-data/docs/note-1*.txt` (deletes 10 files) and `terraform apply`. The source bucket gets delete markers, since it’s versioned.
1. Run the task with `PRESERVE`. Nothing is removed from the destination.
1. Switch to `REMOVE`, `terraform apply`, and run again. The files disappear from the destination listing, but `aws s3api list-object-versions` on the dest bucket still shows the old versions, with delete markers on top. The 7-day lifecycle rule is what eventually removes them.

Keep in mind that `REMOVE` makes the destination a strict mirror, so it would delete anything in the destination that isn’t in the source. That’s fine for this lab but dangerous on a destination that holds other data.

In the deletion mode with task in `PRESERVE` mode the following output is noted:
```zsh
 aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN" \
  --query '{Status:Status,Files:FilesTransferred,Bytes:BytesTransferred,Result:Result}'
{
    "Status": "SUCCESS",
    "Files": 0,
    "Bytes": 0,
    "Result": {
        "PrepareDuration": 1351,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 1655,
        "TransferDuration": 233,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 5,
        "VerifyStatus": "SUCCESS"
    }
}

aws s3 ls s3://$(terraform output -raw dest_bucket)/ --recursive | wc -l
      23
aws s3 ls s3://$(terraform output -raw source_bucket)/ --recursive | wc -l
      14
```
so no files were transferred

In the deletion mode with task in `REMOVE` the following output is noted:
```zsh
aws s3 ls s3://$(terraform output -raw dest_bucket)/docs/ | wc -l
      12
aws s3 ls s3://$(terraform output -raw source_bucket)/docs/ | wc -l
      12

aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN" \
  --query '{Status:Status,Files:FilesTransferred,Bytes:BytesTransferred,Result:Result}'
{
    "Status": "SUCCESS",
    "Files": 0,
    "Bytes": 0,
    "Result": {
        "PrepareDuration": 1312,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 1766,
        "TransferDuration": 339,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 38,
        "VerifyStatus": "SUCCESS"
    }
}

and
FilesVerified is 0

or
❯ aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN" \
  --query '{Status:Status,Transferred:FilesTransferred,Deleted:FilesDeleted,Skipped:FilesSkipped,Verified:FilesVerified,Result:Result}'
{
    "Status": "SUCCESS",
    "Transferred": 0,
    "Deleted": 10,
    "Skipped": 13,
    "Verified": 0,
    "Result": {
        "PrepareDuration": 1312,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 1766,
        "TransferDuration": 339,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 38,
        "VerifyStatus": "SUCCESS"
    }
}
```

### File mode testings

desribe-task-execution query for datasync is (having obtained `EXEC_ARN` variable)

```zsh
aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN" \
  --query '{Status:Status,Transferred:FilesTransferred,Deleted:FilesDeleted,Skipped:FilesSkipped,Verified:FilesVerified,Result:Result}'
```

#### The verify_mode test

Explanation of the various mode for `verify_mode`:
- **POINT_IN_TIME_CONSISTENT**  Default for basic mode. At the end of the transfer task, DataSync scans the entire source and entire destination locations to verify that they are 100% fully synchronized.
  - **Not supported when using `ENHANCED` mode**
- **ONLY_FILES_TRANSFERRED** Recommended for Enhanced Mode
  - calculates the checksum at the source before/during transit, and then compares it to the checksum at the destination once the transfer completes. It skips re-verifying untouched files already residing at both locations.
- **None** does not perform any extra verification scans at the end of the task execution.

I ran the task three times back to back with no source changes, using a different mode each time. I captured each execution ARN, wait for it to finish, then run the query above

```zsh
# 1. Baseline: only files transferred (nothing changed, so little or nothing to verify)
EXEC_ARN=$($(terraform output -raw start_task_command) \
  --override-options VerifyMode=ONLY_FILES_TRANSFERRED \
  --query TaskExecutionArn --output text)

# 2. Full scan of the destination
EXEC_ARN=$($(terraform output -raw start_task_command) \
  --override-options VerifyMode=POINT_IN_TIME_CONSISTENT \
  --query TaskExecutionArn --output text)

# 3. No verification at all
EXEC_ARN=$($(terraform output -raw start_task_command) \
  --override-options VerifyMode=NONE \
  --query TaskExecutionArn --output text)
```

Verify status on each run via the pooling loop

```zsh
while true; do
  S=$(aws datasync describe-task-execution --region ap-southeast-2 \
        --task-execution-arn "$EXEC_ARN" --query Status --output text)
  echo "$(date +%T) $S"
  [[ "$S" == "SUCCESS" || "$S" == "ERROR" ]] && break
  sleep 10
done
```

Here I have a clean three-way comparison, all with no source changes and the same 13 skipped files from the previous deletion experiment:

| Mode | Verified | VerifyStatus | VerifyDuration (ms) | TotalDuration (ms) |
| --- | ---: | --- | ---: | ---: |
| NONE | 0 | PENDING | 0 | 1665 |
| ONLY_FILES_TRANSFERRED | 0 | SUCCESS | 4 | 1660 |
| POINT_IN_TIME_CONSISTENT | 13 | SUCCESS | 1082 | 2762 |

**What the table shows**
- `NONE` vs `ONLY_FILES_TRANSFERRED`. Both verify nothing here, but the status differs. With `NONE` the verify phase never starts, so it stays `PENDING`. With `ONLY_FILES_TRANSFERRED` the phase does run, finds nothing that was transferred, and finishes almost instantly (4 ms) with `SUCCESS`. The same 0 verified count means different things in the two cases: “skipped by design” versus “ran and had nothing to check”.
- `ONLY_FILES_TRANSFERRED` vs `POINT_IN_TIME_CONSISTENT`. The extra second of verification is the full scan of the destination, and it took the total from about 1.7 s to 2.8 s. Only the full-scan mode would catch a file that drifted or went missing at the destination outside DataSync’s own work.
- **Everything else is identical** across the runs (13 skipped, about 1.3 s of preparation, about 270 ms of transfer), which confirms that `verify_mode` only affects the verification phase.

**What PENDING means here**

DataSync reports the phase statuses as `PENDING`, `SUCCESS` or `ERROR`, and `PENDING` is the state a phase sits in when it never ran. My other numbers back that up: `VerifyDuration` is 0 and `Verified` is 0. With `NONE`, the verify phase was skipped entirely, so it never moved past its starting state. It isn’t a stuck or pending job, and the execution as a whole finished with `SUCCESS`.

#### Performing Drift repair

Let's simulate something tampering with an object on the destination bucket

```zsh
echo "tampered" > /tmp/tamper.txt
aws s3 cp /tmp/tamper.txt s3://$(terraform output -raw dest_bucket)/docs/note-01.txt
```

The `options` in `datsync.tf` are
```hcl
options {
    verify_mode            = "ONLY_FILES_TRANSFERRED"
    overwrite_mode         = "ALWAYS" # Default is ALWAYS, but could be NEVER
    transfer_mode          = "CHANGED"
    log_level              = "TRANSFER" # provider default is OFF, which writes no logs
    preserve_deleted_files = "REMOVE" # Default is PRESERVE, but could be REMOVE
    # "REMOVE" mirrors deletes to the destination
```

Then
```zsh
❯ EXEC_ARN=$($(terraform output -raw start_task_command) \
  --override-options VerifyMode=ONLY_FILES_TRANSFERRED \
  --query TaskExecutionArn --output text)

❯ aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN" \
  --query '{Status:Status,Transferred:FilesTransferred,Deleted:FilesDeleted,Skipped:FilesSkipped,Verified:FilesVerified,Result:Result}'
{
    "Status": "SUCCESS",
    "Transferred": 1,
    "Deleted": 0,
    "Skipped": 12,
    "Verified": 1,
    "Result": {
        "PrepareDuration": 1350,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 1811,
        "TransferDuration": 374,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 23,
        "VerifyStatus": "SUCCESS"
    }
}
```

**What happened**
- `Transferred: 1`, `Skipped: 12`. The tampered `note-01.txt` no longer matched the source, so the `CHANGED` comparison treated it as changed and copied it again. `overwrite_mode = ALWAYS` allowed the overwrite. My tampered file was a different size and had a newer timestamp, so either would trigger it (see below observation)
- `Verified: 1`. `ONLY_FILES_TRANSFERRED` verified the one file it had just copied, which is what the mode is meant to do

```zsh
❯ aws s3api list-object-versions --no-cli-pager \
  --bucket $(terraform output -raw dest_bucket) \
  --prefix docs/note-01.txt \
  --query 'Versions[].{VersionId:VersionId,IsLatest:IsLatest,Modified:LastModified,Size:Size}' \
  --output table
---------------------------------------------------------------------------------------
|                                 ListObjectVersions                                  |
+----------+-----------------------------+-------+------------------------------------+
| IsLatest |          Modified           | Size  |             VersionId              |
+----------+-----------------------------+-------+------------------------------------+
|  True    |  2026-10-20T06:52:11+00:00  |  8    |  CLed5OXEJHv_pQ02NWwkqEC8xIxF1DgC  |
|  False   |  2026-10-20T06:49:04+00:00  |  9    |  31YW30G18dMoc1vC3jZpT1UOgdFDVJ2k  |
|  False   |  2026-10-18T23:19:14+00:00  |  8    |  sZN1yU.apzIMHzRquUHk77pznjrjoWzw  |
+----------+-----------------------------+-------+------------------------------------+
```
This table confirms the drift-repair explanation

- To confirm the middle version really holds the tampered content, you can read it by version ID:
```zsh
❯ aws s3api get-object --no-cli-pager \
  --bucket $(terraform output -raw dest_bucket) \
  --key docs/note-01.txt \
  --version-id 31YW30G18dMoc1vC3jZpT1UOgdFDVJ2k \
  /tmp/old-version.txt && cat /tmp/old-version.txt
{
    "AcceptRanges": "bytes",
    "LastModified": "2026-10-20T06:49:04+00:00",
    "ContentLength": 9,
    "ETag": "\"513464b728fd8dec2039cff5710be0ca\"",
    "ChecksumCRC64NVME": "8zL8EIzKqM4=",
    "ChecksumType": "FULL_OBJECT",
    "VersionId": "31YW30G18dMoc1vC3jZpT1UOgdFDVJ2k",
    "ContentType": "text/plain",
    "ServerSideEncryption": "AES256",
    "Metadata": {}
}
tampered
```
- If you want to keep the `tampered` file as latest file you need to `override` the `OverWriteMode` as follows:
```zsh
aws s3 cp /tmp/tamper.txt s3://$(terraform output -raw dest_bucket)/docs/note-01.txt

EXEC_ARN=$($(terraform output -raw start_task_command) \
  --override-options OverwriteMode=NEVER,VerifyMode=ONLY_FILES_TRANSFERRED \
  --query TaskExecutionArn --output text)
```

Check with command
```zsh
aws s3 cp s3://$(terraform output -raw dest_bucket)/docs/note-01.txt -
```
"-" represents standard output in this conext

#### Introducing an error and debugging

While pooling the command above with `OverwriteMode=NEVER", the polling produced the following output:
```zsh
❯ while true; do
  S=$(aws datasync describe-task-execution --region ap-southeast-2 \
        --task-execution-arn "$EXEC_ARN" --query Status --output text)
  echo "$(date +%T) $S"
  [[ "$S" == "SUCCESS" || "$S" == "ERROR" ]] && break
  sleep 10
done
20:39:19 LAUNCHING
20:39:30 LAUNCHING
20:39:40 LAUNCHING
20:39:51 LAUNCHING
20:40:01 LAUNCHING
20:40:11 LAUNCHING
20:40:22 LAUNCHING
20:40:33 LAUNCHING
20:40:43 LAUNCHING
20:40:53 ERROR

❯ aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN" \
  --query '{Status:Status,Transferred:FilesTransferred,Skipped:FilesSkipped,Verified:FilesVerified,VerifyFailed:FilesFailed,Result:Result}'
{
    "Status": "ERROR",
    "Transferred": 0,
    "Skipped": 13,
    "Verified": 13,
    "VerifyFailed": null,
    "Result": {
        "PrepareDuration": 1363,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 2774,
        "TransferDuration": 253,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 1100,
        "VerifyStatus": "ERROR",
        "ErrorCode": "CompleteWithErrorLogsWithVerificationErrorTaskReports",
        "ErrorDetail": "Transfer and verification completed. Verification detected mismatches. See a list of files with mismatches in task reports and CloudWatch logs. If no files are listed, contact AWS Support."
    }
}
```
**What it shows**

Same state, same overrides apart from VerifyMode, opposite outcomes:

| Run | Overwrite | Verify mode | Verified | Status |
| --- | --- | --- | ---: | --- |
| Previous | NEVER | ONLY_FILES_TRANSFERRED | 0 | SUCCESS |
| This one | NEVER | POINT_IN_TIME_CONSISTENT | 13 | ERROR |

The destination held tampered content in both runs. The lightweight mode reported success because it only checks files it just transferred, and nothing was transferred. The full-scan mode compared all 13 files and flagged the mismatch.

**Find the mismatch in the logs and report**

```zsh
aws logs tail /aws/datasync/s3tos3 --region ap-southeast-2 --since 30m | grep -i -E "note-01|mismatch|verif"

noting
2026-10-20T07:40:21.918000+00:00 task-00d85e7072195ae0c-exec-0d2b1c23e1f17bb93 [NOTICE] Verification failed <> /docs/note-01.txt
```
So summarising to correct drift

```zsh
❯ EXEC_ARN=$($(terraform output -raw start_task_command) \
  --override-options VerifyMode=ONLY_FILES_TRANSFERRED \
  --query TaskExecutionArn --output text)

echo $EXEC_ARN

# Polling for completion
while true; do
  S=$(aws datasync describe-task-execution --region ap-southeast-2 \
        --task-execution-arn "$EXEC_ARN" --query Status --output text)
  echo "$(date +%T) $S"
  [[ "$S" == "SUCCESS" || "$S" == "ERROR" ]] && break
  sleep 10
done

❯ aws datasync --no-cli-pager describe-task-execution --region ap-southeast-2 \
  --task-execution-arn "$EXEC_ARN" \
  --query '{Status:Status,Transferred:FilesTransferred,Skipped:FilesSkipped,Verified:FilesVerified,VerifyFailed:FilesFailed,Result:Result}'
{
    "Status": "SUCCESS",
    "Transferred": 1,
    "Skipped": 12,
    "Verified": 1,
    "VerifyFailed": null,
    "Result": {
        "PrepareDuration": 1583,
        "PrepareStatus": "SUCCESS",
        "TotalDuration": 4938,
        "TransferDuration": 3099,
        "TransferStatus": "SUCCESS",
        "VerifyDuration": 272,
        "VerifyStatus": "SUCCESS"
    }
}

# final check
❯ aws s3 cp s3://$(terraform output -raw dest_bucket)/docs/note-01.txt -
note 01
```

