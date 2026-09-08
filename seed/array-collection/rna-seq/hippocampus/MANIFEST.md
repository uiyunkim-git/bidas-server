# The Array Collection — hippocampus

| | |
| --- | --- |
| Bucket | `array-collection` |
| Prefix | `rna-seq/hippocampus/` |
| Assay | RNA-Seq |
| Brain region | hippocampus |
| Cohort | 35 each: schizophrenia, bipolar disorder, controls |

## Contents

No sequencing files have been uploaded to this prefix yet.

## Uploading data here

```bash
# one directory of FASTQ files
mc cp --recursive /path/to/fastq/ bidas/array-collection/rna-seq/hippocampus/

# or keep a local directory in sync
mc mirror --overwrite /path/to/fastq/ bidas/array-collection/rna-seq/hippocampus/
```

Replace this file with a real manifest (sample ID, file name, size, md5, read
length, library prep) once the data is in place.
