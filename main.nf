#!/usr/bin/env nextflow

nextflow.enable.dsl = 2
import groovy.json.JsonBuilder

include { fastq_ingress } from './lib/fastqingress'


process concatFastq {
    label "wfbacterialgenomes"
    cpus 1
    input:
        tuple path("input"), val(meta)
    output:
        tuple val(meta.sample_id), path("${meta.sample_id}.reads.fastq.gz"), emit: read
        path "*stats*", emit: stats
    shell:
    """
    # TODO: could do better here
    fastcat -s "${meta.sample_id}" -r "${meta.sample_id}.stats" -x input | bgzip > "${meta.sample_id}.reads.fastq.gz"
    SAMPLE_ID="${meta.sample_id}"
    """
}


process readStats {
    label "wfbacterialgenomes"
    cpus 1
    input:
        tuple val(sample_id), path("align.bam"), path("align.bam.bai")
    output:
        path "*readstats.txt", emit: stats
    """
    bamstats align.bam > "${sample_id}.readstats.txt"
    if [[ \$(wc -l <"${sample_id}.readstats.txt") -le 1 ]]; then
        echo "No alignments of reads to reference sequence found."
        exit 1
    fi
    """
}


process coverStats {
    label "wfbacterialgenomes"
    cpus 2
    input:
        tuple val(sample_id), path("align.bam"), path("align.bam.bai")
    output:
        path "*fwd.regions.bed.gz", emit: fwd
        path "*rev.regions.bed.gz", emit: rev
        path "*total.regions.bed.gz", emit: all

    """
    mosdepth -n --fast-mode --by 200 --flag 16 -t $task.cpus "${sample_id}.fwd" align.bam
    mosdepth -n --fast-mode --by 200 --include-flag 16 -t $task.cpus "${sample_id}.rev" align.bam
    mosdepth -n --fast-mode --by 200 -t $task.cpus "${sample_id}.total" align.bam
    """
}


process deNovo {
    label "wfbacterialgenomes"
    cpus params.threads
    input:
        tuple val(sample_id), path("reads.fastq.gz")
    output:
        tuple val(sample_id), path("${sample_id}.draft_assembly.fasta.gz"), path("${sample_id}_flye_stats.tsv")
    script:
    """
    flye --nano-raw reads.fastq.gz --out-dir output --threads "${task.cpus}"
    mv output/assembly.fasta "./${sample_id}.draft_assembly.fasta"
    mv output/assembly_info.txt "./${sample_id}_flye_stats.tsv"
    bgzip "${sample_id}.draft_assembly.fasta"
    """
}


process alignReads {
    label "wfbacterialgenomes"
    cpus params.threads
    input:
        tuple val(sample_id), path("reads.fastq.gz"), path("ref.fasta.gz")
    output:
        tuple val(sample_id), path("*reads2ref.bam"), path("*reads2ref.bam.bai")
    """
    mini_align -i reads.fastq.gz -r ref.fasta.gz -p "${sample_id}.reads2ref" -t $task.cpus -m
    """
}


process splitRegions {
    // split the bam reference sequences into overlapping sub-regions

    label "medaka"
    cpus 1
    input:
        tuple val(sample_id), path("align.bam"), path("align.bam.bai")
    output:
        stdout
    """
    #!/usr/bin/env python

    import itertools
    import medaka.common

    regions = itertools.chain.from_iterable(
        x.split(${params.chunk_size}, overlap=1000, fixed_size=False)
        for x in medaka.common.get_bam_regions("align.bam"))
    region_list = []
    for reg in regions:
        # don't ask...just grep &split!
        print("${sample_id}" + '&split!' + str(reg))
    """
}


// TODO: in a single GPU environment it would be better just
//       to use a single process for the whole bam file. Need
//       to read up on conditional channels

process medakaNetwork {
    // run medaka consensus for each region

    label "medaka"
    cpus 2
    input:
        tuple val(sample_id), val(reg), path("align.bam"), path("align.bam.bai"), val(medaka_model)
    output:
        tuple val(sample_id), path("*consensus_probs.hdf")
    script:
        def model = medaka_model
    """
    medaka --version
    echo ${model}
    echo ${medaka_model}
    medaka consensus align.bam "${sample_id}.consensus_probs.hdf" \
        --threads 2 --regions "${reg}" --model ${model}
    """
}


process medakaVariantConsensus {
    // run medaka consensus for each region

    label "medaka"
    cpus 2
    input:
        tuple val(sample_id), val(reg), path("align.bam"), path("align.bam.bai"), val(medaka_model)
    output:
        tuple val(sample_id), path("*consensus_probs.hdf")
    script:
        def model = medaka_model
    """
    medaka --version
    echo ${model}
    echo ${medaka_model}
    medaka consensus align.bam "${sample_id}.consensus_probs.hdf" \
        --threads 2 --regions "${reg}" --model ${model}
    """
}


process medakaVariant {
    label "medaka"
    cpus 1
    input:
        tuple val(sample_id), path("consensus_probs*.hdf"),  path("align.bam"), path("align.bam.bai"), path("ref.fasta.gz")
    output:
        path "${sample_id}.medaka.vcf.gz", emit: variants
        path "${sample_id}.variants.stats", emit: variant_stats
    // note: extension on ref.fasta.gz might not be accurate but shouldn't (?) cause issues.
    //       Also the first step may create an index if not already existing so the alternative
    //       reference.* will break
    """
    medaka variant ref.fasta.gz consensus_probs*.hdf vanilla.vcf
    medaka tools annotate vanilla.vcf ref.fasta.gz align.bam "${sample_id}.medaka.vcf"
    bgzip -i "${sample_id}.medaka.vcf"
    bcftools stats  "${sample_id}.medaka.vcf.gz" > "${sample_id}.variants.stats"
    """
}

process assemblyStats {
    label "wfbacterialgenomes"
    cpus 1
    input:
         path(sample_assembly)

    output:
        tuple path("quast_output/transposed_report.tsv"), path("quast_output/quast_downloaded_references/")

    """
    metaquast.py -o quast_output -t $task.cpus ${sample_assembly}
    """
}


process medakaConsensus {
    label "medaka"
    cpus 1
    input:
        tuple val(sample_id), path("consensus_probs*.hdf"),  path("align.bam"), path("align.bam.bai"), path("reference*")
    output:
        tuple val(sample_id), path("${sample_id}.medaka.fasta.gz")

    """
    medaka stitch --threads $task.cpus consensus_probs*.hdf reference* "${sample_id}.medaka.fasta"
    bgzip "${sample_id}.medaka.fasta"
    """
}


process runProkka {
    // run prokka in a basic way on the consensus sequence
    label "prokka"
    cpus params.threads
    input:
        tuple val(sample_id), path("consensus.fasta.gz")
    output:
        path "*prokka_results/*prokka.gbk"

    script:
        def prokka_opts = "${params.prokka_opts}" == null ? "${params.prokka_opts}" : ""
    """
    echo $sample_id
    gunzip -rf consensus.fasta.gz
    prokka $prokka_opts --outdir "${sample_id}.prokka_results" \
        --cpus $task.cpus --prefix "${sample_id}.prokka" *consensus.fasta
    
    """
}


process prokkaVersion {
    label "prokka"
    output:
        path "prokka_version.txt"
    """
    prokka --version | sed 's/ /,/' >> "prokka_version.txt"
    """
}

process medakaVersion {
    label "medaka"
    input:
        path "input_versions.txt"
    output:
        path "medaka_version.txt"
    """
    cat "input_versions.txt" >> "medaka_version.txt"
    medaka --version | sed 's/ /,/' >> "medaka_version.txt"
    """
}

process getVersions {
    label "wfbacterialgenomes"
    cpus 1
    input:
        path "input_versions.txt"
    output:
        path "versions.txt"
    """
    cat "input_versions.txt" >> versions.txt
    python -c "import pysam; print(f'pysam,{pysam.__version__}')" >> versions.txt
    fastcat --version | sed 's/^/fastcat,/' >> versions.txt
    mosdepth --version | sed 's/ /,/' >> versions.txt
    flye --version | sed 's/^/flye,/' >> versions.txt
    python -c "import pomoxis; print(f'pomoxis,{pomoxis.__version__}')" >> versions.txt
    python -c "import dna_features_viewer; print(f'dna_features_viewer,{dna_features_viewer.__version__}')" >> versions.txt
    """
}


process getParams {
    label "wfbacterialgenomes"
    cpus 1
    output:
        path "params.json"
    script:
        def paramsJSON = new JsonBuilder(params).toPrettyString()
    """
    # Output nextflow params object to JSON
    echo '$paramsJSON' > params.json
    """
}


process makeReport {
    label "wfbacterialgenomes"
    cpus 1
    input:
        path "versions/*"
        path "params.json"
        path "variants/*"
        val sample_ids
        path "prokka/*"
        path "stats/*"
        path "fwd/*"
        path "rev/*"
        path "total_depth/*"
        path "quast_stats/*"
        path "flye_stats/*"
    output:
        path "wf-bacterial-genomes-*.html"
    script:
        report_name = "wf-bacterial-genomes-report.html"
        denovo = params.reference_based_assembly as Boolean ? "" : "--denovo"
        prokka = params.run_prokka as Boolean ? "--prokka" : ""
        samples = sample_ids.join(" ")
    // NOTE: the script assumes the various subdirectories
    """
    workflow-glue report \
    $prokka $denovo \
    --versions versions \
    --params params.json \
    --output $report_name \
    --sample_ids $samples 
    """
}


// See https://github.com/nextflow-io/nextflow/issues/1636
// This is the only way to publish files from a workflow whilst
// decoupling the publish from the process steps.
process output {
    // publish inputs to output directory
    label "wfbacterialgenomes"
    publishDir "${params.out_dir}", mode: 'copy', pattern: "*"
    input:
        path fname
    output:
        path fname
    """
    echo "Writing output files"
    """
}


process lookup_medaka_consensus_model {
    label "wfbacterialgenomes"
    input:
        path("lookup_table")
        val basecall_model
    output:
        stdout
    shell:
    '''
    medaka_model=$(workflow-glue resolve_medaka_model lookup_table '!{basecall_model}' "medaka_consensus")
    echo $medaka_model
    '''
}


process lookup_medaka_variant_model {
    label "wfbacterialgenomes"
    input:
        path("lookup_table")
        val basecall_model
    output:
        stdout
    shell:
    '''
    medaka_model=$(workflow-glue resolve_medaka_model lookup_table '!{basecall_model}' "medaka_variant")
    echo $medaka_model
    '''
}


// modular workflow
workflow calling_pipeline {
    take:
        reads
        reference
    main:
        reads = concatFastq(reads)
        sample_ids = reads.read.map { it -> it[0] }
        if (params.reference_based_assembly && !params.reference){
            throw new Exception("Reference based assembly selected, a reference sequence must be provided through the --reference parameter.")
        }
        if (!params.reference_based_assembly){
            log.info("Running Denovo assembly.")
            denovo_assem = deNovo(reads.read)
            named_refs = denovo_assem.map { it -> [it[0], it[1]] }
            read_ref_groups = reads.read.join(named_refs)
        } else {
            log.info("Reference based assembly selected.")
            references = channel.fromPath(params.reference)
            read_ref_groups = reads.read.combine(references)
            named_refs = read_ref_groups.map { it -> [it[0], it[2]] }
        }
        alignments = alignReads(read_ref_groups)
        read_stats = readStats(alignments)
        depth_stats = coverStats(alignments)
        regions = splitRegions(alignments).splitText()
        named_regions = regions.map {
            it -> return tuple(it.split(/&split!/)[0], it.split(/&split!/)[1])
        }

        if(params.medaka_consensus_model) {
            log.warn "Overriding Medaka Consensus model with ${params.medaka_consensus_model}."
            medaka_consensus_model = Channel.fromList([params.medaka_consensus_model])
        }
        else {
            lookup_table = Channel.fromPath("${projectDir}/data/medaka_models.tsv", checkIfExists: true)
            medaka_consensus_model = lookup_medaka_consensus_model(lookup_table, params.basecaller_cfg)
        }
        if(params.medaka_variant_model) {
            log.warn "Overriding Medaka Variant model with ${params.medaka_variant_model}."
            medaka_variant_model = Channel.fromList([params.medaka_variant_model])
        }
        else {
            lookup_table = Channel.fromPath("${projectDir}/data/medaka_models.tsv", checkIfExists: true)
            medaka_variant_model = lookup_medaka_variant_model(lookup_table, params.basecaller_cfg)
        }

        // medaka consensus
        regions_bams = named_regions.combine(alignments, by: [0])
        regions_model = regions_bams.combine(medaka_consensus_model)
        hdfs = medakaNetwork(regions_model)
        hdfs_grouped = hdfs.groupTuple().combine(alignments, by: [0]).join(named_refs)
        consensus = medakaConsensus(hdfs_grouped)

        // post polishing, do assembly specific things
        assem_stats = assemblyStats(consensus.collect({it -> it[1]}))
        
        if (!params.reference_based_assembly){
            flye_info = denovo_assem.map { it -> it[2] }
        }else{
            flye_info = Channel.empty()
        }

        // medaka variants
        if (params.reference_based_assembly){
            bam_model = regions_bams.combine(medaka_variant_model)
            hdfs_variant = medakaVariantConsensus(bam_model)
            hdfs_grouped = hdfs_variant.groupTuple().combine(alignments, by: [0]).join(named_refs)
            variant = medakaVariant(hdfs_grouped)
            variants = variant.variant_stats
            vcf_variant = variant.variants
        } else {
            variants = Channel.empty()
            vcf_variant = Channel.empty()
        }

        if (params.run_prokka) {
            prokka = runProkka(consensus)
        } else {
            prokka = Channel.empty()
        }
        prokka_version = prokkaVersion()
        medaka_version = medakaVersion(prokka_version)
        software_versions = getVersions(medaka_version)
        workflow_params = getParams()

        report = makeReport(
            software_versions.collect(),
            workflow_params,
            variants.collect().ifEmpty(file("${projectDir}/data/OPTIONAL_FILE")),
            sample_ids.collect(),
            prokka.collect().ifEmpty(file("${projectDir}/data/OPTIONAL_FILE")),
            reads.stats.collect(),
            depth_stats.fwd.collect(),
            depth_stats.rev.collect(),
            depth_stats.all.collect(),
            assem_stats.collect().ifEmpty(file("${projectDir}/data/OPTIONAL_FILE")),
            flye_info.collect().ifEmpty(file("${projectDir}/data/OPTIONAL_FILE")))
        telemetry = workflow_params
        all_out = variants.concat(
            vcf_variant,
            alignments.map {it -> it[1]},
            consensus.map {it -> it[1]},
            report,
            prokka)

    emit:
        all_out
        telemetry
}


// entrypoint workflow
WorkflowMain.initialise(workflow, params, log)
workflow {
    if (params.disable_ping == false) {
        Pinguscript.ping_post(workflow, "start", "none", params.out_dir, params)
    }

    samples = fastq_ingress([
        "input":params.fastq,
        "sample":params.sample,
        "sample_sheet":params.sample_sheet])

    reference = params.reference
    results = calling_pipeline(samples, reference)
    output(results.all_out)
}

if (params.disable_ping == false) {
    workflow.onComplete {
        Pinguscript.ping_post(workflow, "end", "none", params.out_dir, params)
    }

    workflow.onError {
        Pinguscript.ping_post(workflow, "error", "$workflow.errorMessage", params.out_dir, params)
    }
}
