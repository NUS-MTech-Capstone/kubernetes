#!/usr/bin/env ruby
# Validate GitOps declarations and, optionally, registry/platform runtime identity.
require 'json'
require 'yaml'
require 'open3'

module ImageDigests
  DIGEST = /\Asha256:[a-f0-9]{64}\z/
  def self.digest(image)
    value = image.to_s.split('@', 2)[1]
    raise "image must use a sha256 digest: #{image}" unless value && DIGEST.match?(value)
    value
  end

  def self.runtime_matches?(expected, actual, manifest)
    return true if expected == actual
    return false unless DIGEST.match?(actual.to_s)
    # An OCI index identifies several platform manifests. The runtime reports
    # the selected child, while GitOps records the immutable parent index.
    Array(manifest['manifests']).any? { |child| child['digest'] == actual }
  end

  def self.capture(*args)
    out, err, status = Open3.capture3(*args)
    raise "#{args.first} failed: #{err.strip}" unless status.success?
    out
  end

  def self.verify(documents, live: false, allow_tags: false)
    expected = {}
    documents.compact.each do |document|
      next unless %w[Deployment Job].include?(document['kind'])
      metadata = document.fetch('metadata')
      spec = document.fetch('spec').fetch('template').fetch('spec')
      (Array(spec['containers']) + Array(spec['initContainers'])).each do |container|
        image = container.fetch('image')
        digest(image) unless allow_tags && !image.include?('@')
        expected[[metadata['namespace'] || 'default', metadata['name'], container['name']]] = image if document['kind'] == 'Deployment'
      end
    end
    raise 'no deployment images found' if expected.empty?
    return expected unless live
    raise '--live cannot allow tag-only images' if allow_tags
    cluster = JSON.parse(capture('kubectl', 'get', 'deployments,pods', '--all-namespaces', '-l', 'app=dendenmushi', '-o', 'json'))
    pods = cluster.fetch('items').select { |item| item['kind'] == 'Pod' && !item.dig('metadata', 'deletionTimestamp') }
    manifests = {}
    cluster.fetch('items').select { |item| item['kind'] == 'Deployment' }.each do |deployment|
      namespace = deployment.dig('metadata', 'namespace')
      name = deployment.dig('metadata', 'name')
      labels = deployment.dig('spec', 'selector', 'matchLabels')
      running = pods.select { |pod| pod.dig('metadata', 'namespace') == namespace && labels.all? { |k,v| pod.dig('metadata', 'labels', k) == v } }
      raise "#{namespace}/#{name}: no running pods" if running.empty?
      deployment.dig('spec', 'template', 'spec', 'containers').each do |container|
        key = [namespace, name, container['name']]
        wanted = expected.delete(key)
        raise "#{key.join('/')}: differs from rendered GitOps image" unless wanted == container['image']
        wanted_digest = digest(wanted)
        running.each do |pod|
          declared = pod.dig('spec', 'containers').find { |c| c['name'] == container['name'] }
          status = Array(pod.dig('status', 'containerStatuses')).find { |c| c['name'] == container['name'] }
          raise "#{key.join('/')}: pod is not ready on the expected image" unless declared && declared['image'] == wanted && status && status['ready']
          actual = status.fetch('imageID').split('@').last.sub(/\A[^:]+:\/\//, '')
          if wanted_digest != actual
            registry, repository = wanted.split('@').first.split('/', 2)
            raise "#{key.join('/')}: unsupported registry for platform verification" unless registry =~ /\A\d{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com\z/
            region = Regexp.last_match(1)
            manifests[wanted] ||= begin
              result = JSON.parse(capture('aws', 'ecr', 'batch-get-image', '--region', region, '--repository-name', repository,
                '--image-ids', "imageDigest=#{wanted_digest}", '--output', 'json'))
              image = Array(result['images']).find { |entry| entry.dig('imageId', 'imageDigest') == wanted_digest }
              raise "#{key.join('/')}: ECR index unavailable" unless image
              JSON.parse(image.fetch('imageManifest'))
            end
            raise "#{key.join('/')}: runtime digest is not a child of the declared image index" unless runtime_matches?(wanted_digest, actual, manifests[wanted])
          end
          puts JSON.generate(namespace: namespace, deployment: name, container: container['name'], declaredImage: wanted, runtimeDigest: actual)
        end
      end
    end
    raise "missing deployments: #{expected.keys.map { |k| k.join('/') }.join(', ')}" unless expected.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  live = ARGV.delete('--live')
  allow_tags = ARGV.delete('--allow-tags')
  path = ARGV.shift || File.expand_path('../apps/dendenmushi/overlays/dev', __dir__)
  documents = YAML.load_stream(File.file?(path) ? File.read(path) : ImageDigests.capture('kubectl', 'kustomize', path))
  ImageDigests.verify(documents, live: !!live, allow_tags: !!allow_tags)
  puts 'Image digest verification passed.'
end
