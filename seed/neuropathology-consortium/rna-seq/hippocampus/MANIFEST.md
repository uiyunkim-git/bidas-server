# The Neuropathology Consortium — hippocampus

| | |
| --- | --- |
| Bucket | `neuropathology-consortium` |
| Prefix | `rna-seq/hippocampus/` |
| Assay | RNA-Seq |
| Brain region | hippocampus |
| Cohort | 15 each: schizophrenia, bipolar disorder, depression, controls |

## Contents

No sequencing files have been uploaded to this prefix yet.

## Uploading data here

```bash
# one directory of FASTQ files
mc cp --recursive /path/to/fastq/ bidas/neuropathology-consortium/rna-seq/hippocampus/

# or keep a local directory in sync
mc mirror --overwrite /path/to/fastq/ bidas/neuropathology-consortium/rna-seq/hippocampus/
```

Replace this file with a real manifest (sample ID, file name, size, md5, read
length, library prep) once the data is in place.
