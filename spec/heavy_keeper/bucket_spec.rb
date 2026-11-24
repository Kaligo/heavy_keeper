RSpec.describe HeavyKeeper::Bucket do
  let(:redis) { MockRedis.new }
  let(:bucket) { described_class.new(redis) }

  describe '#set' do
    it 'sets data correctly' do
      expect { bucket.set('users', 1, 2, ['fingerprint', 10]) }
        .to change { redis.hget('cache_prefix_bucket:hash:users', '1:2') }
        .from(nil).to('["fingerprint",10]')
    end
  end

  describe '#get' do
    subject { bucket.get('users', 1, 2) }

    context 'when data is empty' do
      it { is_expected.to eq nil }
    end

    context 'when data exists' do
      before { bucket.set('users', 1, 2, ['fingerprint', 10]) }

      it { is_expected.to eq ['fingerprint', 10] }
    end
  end
end
