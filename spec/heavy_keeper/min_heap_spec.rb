RSpec.describe HeavyKeeper::MinHeap do
  let(:redis) { MockRedis.new }
  let(:min_heap) { described_class.new(redis) }

  describe '#list' do
    let(:key) { 'users' }
    let(:top_k) { 3 }
    subject { min_heap.list(key, top_k) }

    before do
      min_heap.add('users', 'item_1', 10, top_k)
      min_heap.add('users', 'item_2', 7, top_k)
      min_heap.add('users', 'item_3', 14, top_k)
      min_heap.add('users', 'item_4', 4, top_k)
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
      before { min_heap.add(key, item, 10, 1) }

      it { is_expected.to eq 10 }
    end
  end

  describe '#min' do
    let(:key) { 'users' }
    let(:top_k) { 3 }
    subject { min_heap.min(key) }

    before do
      min_heap.add('users', 'item_1', 10, top_k)
      min_heap.add('users', 'item_2', 7, top_k)
      min_heap.add('users', 'item_3', 14, top_k)
      min_heap.add('users', 'item_4', 4, top_k)
    end

    it { is_expected.to eq 7 }
  end

  describe '#exist?' do
    let(:key) { 'users' }
    let(:item) { 'item' }
    subject { min_heap.exist?(key, item) }

    context 'when there is no data' do
      it { is_expected.to eq false }
    end

    context 'when there is data' do
      before { min_heap.add(key, item, 10, 1) }

      it { is_expected.to eq true }
    end
  end

  describe '#add' do
    let(:key) { 'users' }
    let(:item) { 'item' }
    subject { min_heap.add(key, item, 10, top_k) }

    context 'when heap size is smaller than K after adding' do
      let(:top_k) { 3 }
      before { min_heap.add(key, 'item_2', 1, 3) }

      it 'adds item successfully' do
        expect do
          expect(subject).to eq 10
        end.to change { min_heap.exist?(key, item) }.from(false).to(true)
      end

      it 'does not drop existing item' do
        expect { subject }.not_to change { min_heap.exist?(key, 'item_2') }
      end
    end

    context 'when heap size is bigger than K after adding and new item is smaller than min item' do
      let(:top_k) { 1 }
      before { min_heap.add(key, 'item_2', 100, 1) }

      it 'does not add item' do
        expect do
          expect(subject).to eq nil
        end.not_to change { min_heap.exist?(key, item) }
      end

      it 'does not drop existing item' do
        expect { subject }.not_to change { min_heap.exist?(key, 'item_2') }
      end
    end

    context 'when heap size is bigger than K after adding and new item is bigger than min item' do
      let(:top_k) { 1 }
      before { min_heap.add(key, 'item_2', 1, 1) }

      it 'adds item successfully' do
        expect do
          expect(subject).to eq 10
        end.to change { min_heap.exist?(key, item) }.from(false).to(true)
      end

      it 'drops existing item' do
        expect { subject }.to change { min_heap.exist?(key, 'item_2') }.from(true).to(false)
      end
    end
  end

  describe '#update' do
    let(:key) { 'users' }
    let(:item) { 'item' }
    subject { min_heap.update(key, item, 10) }

    context 'when item does not exist' do
      it 'adds item successfully' do
        expect do
          expect(subject).to eq 10
        end.to change { min_heap.exist?(key, item) }.from(false).to(true)
          .and change { min_heap.count(key, item) }.from(0).to(10)
      end
    end

    context 'when item exists' do
      before { min_heap.add(key, item, 1, 1) }

      it 'updates item successfully' do
        expect do
          expect(subject).to eq 10
        end.to change { min_heap.count(key, item) }.from(1).to(10)
      end

      it 'does not change item existence' do
        expect { subject }.not_to change { min_heap.exist?(key, item) }
      end
    end
  end

  describe '#clear' do
    context 'when there is no data' do
      it 'runs successfully' do
        min_heap.clear('users')
      end
    end

    context 'when there is data' do
      before { min_heap.add('users', 'item', 10, 1) }

      it 'runs successfully' do
        expect do
          min_heap.clear('users')
        end.to change { [min_heap.exist?('users', 'item'), min_heap.count('users', 'item')] }
          .from([true, 10]).to([false, 0])
      end
    end
  end

  describe '#delete' do
    context 'when there is no data' do
      before { min_heap.add('users', 'item', 10, 1) }

      it 'runs successfully without affecting other fields' do
        expect do
          min_heap.delete('users', 'not_item')
        end.to not_change { min_heap.exist?('users', 'item') }
      end
    end

    context 'when there is data' do
      before { min_heap.add('users', 'item', 10, 1) }

      it 'runs delete item successfully' do
        expect do
          min_heap.delete('users', 'item')
        end.to change { min_heap.exist?('users', 'item') }
          .from(true).to(false)
      end
    end
  end
end
