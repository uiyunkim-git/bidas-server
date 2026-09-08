# The Neuropathology Consortium — prefrontal cortex

| | |
| --- | --- |
| Bucket | `neuropathology-consortium` |
| Prefix | `rna-seq/prefrontal-cortex/` |
| Assay | RNA-Seq |
| Brain region | prefrontal cortex |
| Cohort | 15 each: schizophrenia, bipolar disorder, depression, controls |

## Contents

No sequencing files have been uploaded to this prefix yet.

## Uploading data here

```bash
# one directory of FASTQ files
mc cp --recursive /path/to/fastq/ bidas/neuropathology-consortium/rna-seq/prefrontal-cortex/

# or keep a local directory in sync
mc mirror --overwrite /path/to/fastq/ bidas/neuropathology-consortium/rna-seq/prefrontal-cortex/
```

Replace this file with a real manifest (sample ID, file name, size, md5, read
length, library prep) once the data is in place.
