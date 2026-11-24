RSpec.describe HeavyKeeper::MinHeap do
  let(:redis) { MockRedis.new }
  let(:min_heap) { described_class.new(redis) }

  # TopK writes the min-heap in increase_by.lua, so the specs write it directly
  def seed(key, item, value)
    redis.zadd(min_heap.sorted_set_key(key), value, item)
    redis.hset(min_heap.hash_key(key), item, value)
  end

  describe '#list' do
    let(:key) { 'users' }
    let(:top_k) { 3 }
    subject { min_heap.list(key, top_k) }

    before do
      seed('users', 'item_1', 10)
      seed('users', 'item_2', 7)
      seed('users', 'item_3', 14)
      seed('users', 'item_4', 4)
    end

    it { is_expected.to eq({ 'item_3' => '14', 'item_1' => '10', 'item_2' => '7' }) }
  end

  describe '#count' do
    let(:key) { 'users' }
    let(:item) { 'item' }
    subject { min_heap.count(key, item) }

    context 'when there is no data' do
      it { is_expected.to eq 0 }
    end

    context 'when there is data' do
      before { seed(key, item, 10) }

      it { is_expected.to eq 10 }
    end
  end

  describe '#exist?' do
    let(:key) { 'users' }
    let(:item) { 'item' }
    subject { min_heap.exist?(key, item) }

    context 'when there is no data' do
      it { is_expected.to eq false }
    end

    context 'when there is data' do
      before { seed(key, item, 10) }

      it { is_expected.to eq true }
    end
  end

  describe '#delete' do
    context 'when there is no data' do
      before { seed('users', 'item', 10) }

      it 'runs successfully without affecting other fields' do
        expect do
          min_heap.delete('users', 'not_item')
        end.to not_change { min_heap.exist?('users', 'item') }
      end
    end

    context 'when there is data' do
      before { seed('users', 'item', 10) }

      it 'runs delete item successfully' do
        expect do
          min_heap.delete('users', 'item')
        end.to change { min_heap.exist?('users', 'item') }
          .from(true).to(false)
      end
    end
  end
end
