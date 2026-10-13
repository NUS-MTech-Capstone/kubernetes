require 'minitest/autorun'
require_relative '../scripts/verify-image-digests'

class ImageDigestsTest < Minitest::Test
  PARENT = 'sha256:' + 'a' * 64
  CHILD = 'sha256:' + 'b' * 64
  def test_exact_digest_and_index_child
    assert ImageDigests.runtime_matches?(PARENT, PARENT, {})
    assert ImageDigests.runtime_matches?(PARENT, CHILD, {'manifests'=>[{'digest'=>CHILD}]})
    refute ImageDigests.runtime_matches?(PARENT, CHILD, {'manifests'=>[{'digest'=>'sha256:'+'c'*64}]})
    refute ImageDigests.runtime_matches?(PARENT, 'malformed', {})
  end
  def test_missing_or_malformed_digest_is_rejected
    assert_equal PARENT, ImageDigests.digest('registry/service@'+PARENT)
    %w[registry/service:commit registry/service:latest registry/service@sha256:abc].each do |image|
      assert_raises(RuntimeError) { ImageDigests.digest(image) }
    end
  end
  def test_rendered_deployments_and_migration_jobs_require_digests
    documents = %w[Deployment Job].map { |kind| {'kind'=>kind,'metadata'=>{'name'=>'fixture'},'spec'=>{'template'=>{'spec'=>{'containers'=>[{'name'=>'fixture','image'=>'registry/service@'+PARENT}]}}}} }
    assert_equal 1, ImageDigests.verify(documents).length
    documents.last['spec']['template']['spec']['containers'][0]['image']='registry/service:tag'
    assert_raises(RuntimeError) { ImageDigests.verify(documents) }
    assert_equal 1, ImageDigests.verify(documents, allow_tags: true).length
  end
end
