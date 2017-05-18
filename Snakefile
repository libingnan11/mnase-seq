#!/usr/bin/env python

configfile: "config.yaml"

SAMPLES = config["barcodes"]

#localrules: all,
#            make_barcode_file,
#            bowtie_build,
#            build_nucwave_input

#requirements
# seq/ea-utils/
# UNLOAD seq/cutadapt/1.11
# use pip-installed cutadapt
# seq/bowtie/1.1.1
# seq/samtools/1.3
# pip install numpy PyWavelets
# pip install deeptools
# UNLOAD deeptools, pysam

rule all:
    input:
        #expand("fastq/{sample}.r1.fastq.gz", sample=SAMPLES)
        #expand("fastq/trimmed/{sample}-trim.r1.fastq.gz", sample=SAMPLES)
        #expand("alignment/{sample}.bowtie", sample=SAMPLES)
        #expand("nucwave/{sample}/{sample}_depth_c_wl_norm.wig", sample=SAMPLES)
        expand("bedgraph/{sample}.bedgraph", sample=SAMPLES)

rule make_barcode_file:
    output:
        "barcodes.tsv"
    params:
        bc = config["barcodes"]
    run:
        with open(output[0], "w") as out:
            for x in params.bc:
                out.write(('\t'.join((x, params.bc[x]))+'\n'))

rule demultiplex:
    input:
        r1 = config["fastq"]["r1"],
        #r2 = config["fastq"]["r2"],
        barcodes = "barcodes.tsv"
    output:
        r1 = expand("fastq/{sample}.r1.fastq.gz", sample=config["barcodes"]),
        #r2 = expand("fastq/{sample}.r1.fastq.gz", sample=config["barcodes"])
    log:
        "logs/demultiplex.log"
    #shell: """
    #   (fastq-multx -B {input.barcodes} -b {input.r1} -o fastq/%.r1.fastq.gz {input.r2} -o fastq/%.r2.fastq.gz -v '/') &> {log}
    #    """
    shell: """
        (fastq-multx -B {input.barcodes} -b {input.r1} -o fastq/%.r1.fastq.gz) &> {log}
        """
#enforce minimum phred quality to accept barcode base? not likely to make any difference

#here we just use cutadapt to cut the A tail and do quality trimming (no adapter to remove since the barcode is removed in demultiplexing and the read length isn't long enough to read through to the other side)

rule cutadapt:
    input:
        r1 = "fastq/{sample}.r1.fastq.gz",
        #r2 = "fastq/{sample}.r2.fastq.gz"
    output:
        r1 = "fastq/trimmed/{sample}-trim.r1.fastq",
        #r2 = "fastq/trimmed/{sample}-trim.r2.fastq.gz"
    params:
        qual_cutoff = config["cutadapt"]["qual_cutoff"]
    log:
        "logs/cutadapt/cutadapt-{sample}.log"
#    #need to check whether quality is ascii(phred+33) or ascii(phred+64)
#    shell: """
#        cutadapt -u 1 -U 1 --nextseq-trim={params.qual_cutoff} -o {output.r1} -p {output.r2}
#        """
    shell: """
        (cutadapt -u 1 --nextseq-trim={params.qual_cutoff} -o {output.r1} {input.r1}) &> {log}
        """

#build bowtie index for given genome
basename = config["genome"]["name"]

rule bowtie_build:
    input:
        fasta = config["genome"]["fasta"]
    output:
        expand("genome/" + basename + ".{n}.ebwt", n=[1,2,3,4]),
        expand("genome/" + basename + ".rev.{n}.ebwt", n=[1,2])
    params:
        outbase = "genome/" + basename
    log:
        "logs/bowtie-build.log"    
    shell: """
        (bowtie-build {input.fasta} {params.outbase}) &> {log}
        """

rule bowtie:
    input:
        expand("genome/" + basename + ".{n}.ebwt", n=[1,2,3,4]),
        expand("genome/" + basename + ".rev.{n}.ebwt", n=[1,2]),
        r1 = "fastq/trimmed/{sample}-trim.r1.fastq",
        #r2 = "fastq/trimmed/{sample}-trim.r2.fastq.gz"
    output:
        "alignment/{sample}.bam"
    threads: config["threads"]
    params:
        outbase = "genome/" + basename,
        max_mismatch = config["bowtie"]["max_mismatch"],
        min_ins = config["bowtie"]["min_ins"],
        max_ins = config["bowtie"]["max_ins"]
    log:
       "logs/bowtie-align-{sample}.log"
    #shell: """
    #    (bowtie -v {params.max_mismatch} -I {params.min_ins} -X {params.max_ins} --fr --nomaqround --best -S -p {threads} {params.outbase} -1 {input.r1} -2 {input.r2} | samtools view -buh -f 0x2 - | samtools sort -T {wildcards.sample} -@ {threads} -o {output} -) &> {log}
    #    """
    shell: """
        (bowtie -v {params.max_mismatch} --nomaqround --best -S -p {threads} {params.outbase} {input.r1} | samtools view -buh  - | samtools sort -T {wildcards.sample} -@ {threads} -o {output} -) &> {log}
        """

rule samtools_index:
    input:
        "alignment/{sample}.bam"
    output:
        "alignment/{sample}.bam.bai"
    log:
        "logs/samtools_index.log"
    shell: """
        samtools index -b {input} 
        """

rule build_nucwave_input:
    input:
       "alignment/{sample}.bam" 
    output:
       "alignment/{sample}.bowtie"
    #shell: """
    #    samtools view {input} | awk 'BEGIN{{FS=OFS="\t"}} ($2==163) || ($2==99) {{print "+", $3, $4-1, $10}} ($2==83) || ($2==147) {{print "-", $3, $4-1, $10}}' > {output}
    #    """
    shell: """
        samtools view {input} | awk 'BEGIN{{FS=OFS="\t"}} ($2==0) {{print "+", $3, $4-1, $10}} ($2==16) {{print "-", $3, $4-1, $10}}' > {output}
        """

rule nucwave:
    input:
        fasta = config["genome"]["fasta"],
        alignment = "alignment/{sample}.bowtie"
    output:
        "nucwave/{sample}/{sample}_cut_p.wig",
        "nucwave/{sample}/{sample}_cut_m.wig",
        "nucwave/{sample}/{sample}_depth_p.wig",
        "nucwave/{sample}/{sample}_depth_m.wig",
        "nucwave/{sample}/{sample}_depth_p_wl.wig",
        "nucwave/{sample}/{sample}_depth_m_wl.wig",
        "nucwave/{sample}/{sample}_depth_c.wig",
        "nucwave/{sample}/{sample}_depth_c_wl.wig",
        "nucwave/{sample}/{sample}_depth_c_wl_norm.wig",
        #"nucwave/{sample}/{sample}_complete_PE.wig",
        #"nucwave/{sample}/{sample}_PE_center.wig",
        #"nucwave/{sample}/{sample}_depth_trimmed_PE.wig",
        #"nucwave/{sample}/{sample}_wl_trimmed_PE.wig",
        #"nucwave/{sample}/{sample}.historeadsize.wig"
    log:
        "logs/nucwave.log"
    #shell: """
    #   (python scripts/nucwave_pe.py -w -o nucwave/{wildcards.sample} -g {input.fasta} -a {input.alignment} -p {wildcards.sample}) &> {log}
    #   """
    shell: """
        (python scripts/nucwave_sr.py -w -o nucwave/{wildcards.sample} -g {input.fasta} -a {input.alignment} -p {wildcards.sample}) &> {log}
        """

rule midpoint_coverage:
    input:
        bam = "alignment/{sample}.bam",
        index = "alignment/{sample}.bam.bai"
    output:
        "coverage/{sample}-midpoint-coverage-RPM.bedgraph"
    params:
        minsize = config["bowtie"]["min_ins"],
        maxsize = config["bowtie"]["max_ins"]
    threads: config["threads"]
    shell: """
        bamCoverage -b {input.bam} -o {output} -of bedgraph --MNase -bs 1 -p {threads} --normalizeUsingRPKM --minFragmentLength {params.minsize} --maxFragmentLength {params.maxsize}
        """

rule midpoint_coverage_smoothed:
    input:
        bam = "alignment/{sample}.bam",
        index = "alignment/{sample}.bam.bai"
    output:
        "coverage/{sample}-midpoint-coverage-smoothed-RPM.bedgraph"
    params:
        minsize = config["bowtie"]["min_ins"],
        maxsize = config["bowtie"]["max_ins"],
        smoothwindow = config["coverage"]["smooth_window"]
    threads: config["threads"]
    shell: """
        bamCoverage -b {input.bam} -o {output} -of bedgraph --MNase -bs 1 -p {threads} --normalizeUsingRPKM --minFragmentLength {params.minsize} --maxFragmentLength {params.maxsize} --smoothLength {params.smoothwindow}
        """

rule total_coverage:
    input:
        bam = "alignment/{sample}.bam",
        index = "alignment/{sample}.bam.bai"
    output:
        "coverage/{sample}-total-coverage-RPM.bedgraph"
    params:
        minsize = config["bowtie"]["min_ins"],
        maxsize = config["bowtie"]["max_ins"]
    threads: config["threads"]
    shell: """
        bamCoverage -b {input.bam} -o {output} -of bedgraph --extendReads -bs 1 -p {threads} --normalizeUsingRPKM --minFragmentLength {params.minsize} --maxFragmentLength {params.maxsize} 
        """
