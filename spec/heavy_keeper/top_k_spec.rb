# heavykeeper algorithm is complex, so we don't intend to unit test it
# Most behaviors are tested by integration tests, while unit tests only test
# validation and simple interaction.
#
RSpec.describe HeavyKeeper::TopK do
  let(:redis) { Redis.new }
  let(:top_k) { described_class.new(storage: redis) }

  before do
    redis.flushdb
  end

  describe 'integration tests' do
    # there are 10 elements in top-k list, at least 9 elements should be
    # valid value
    let(:size) { 10 }
    let(:min_accuracy) { 0.9 }

    def calculate_accuracy(stream, top_k, size)
      top_items = stream.group_by(&:itself).map { |i, array| [i, array.count] }
        .sort_by { |_i, count| -count }.take(size).to_h
      difference = top_k.list('users').keys - top_items.keys
      1.0 - (difference.count.to_f / size)
    end

    context 'when stream is simple' do
      it 'correctly determines the top element' do
        # we have 4 slots (4 x 1) to store 4 items
        top_k.reserve('users', top_k: 2, width: 4, depth: 1, decay: 0.9)

        100.times { top_k.add('users', 'key_1') }
        10.times { top_k.add('users', 'key_2') }
        top_k.add('users', 'key_3')
        top_k.add('users', 'key_4')

        # key_1 should be ranked highest in the list and have the count nearly
        # correct
        # key_2 should be in the list, too
        expect(top_k.query('users', 'key_1')).to eq [true]
        key_1_count = top_k.count('users', 'key_1').first
        expect(key_1_count).to be <= 100
        expect(key_1_count).to be > 10
        expect(top_k.list('users').keys).to eq %w[key_1 key_2]

        expect(top_k.query('users', 'key_3', 'key_4')).to eq [false, false]
      end
    end

    context 'when stream is dominated by some elephant flows' do
      it 'only correctly determines elephant flows' do
        elephant_flow = (size / 2).times.map(&:to_s)
        mouse_flow = 100.times.map { |i| (size + i).to_s }

        stream =
          mouse_flow.flat_map { |item| [item] * SecureRandom.random_number(20) } +
          elephant_flow.flat_map { |item| [item] * (100 + SecureRandom.random_number(100)) }

        # we have 64 slots (32 x 2) to store 105 items
        top_k.reserve('users', top_k: size, width: 32, depth: 2, decay: 0.9)
        stream.each { |item| top_k.add('users', item) }

        # contains all items in elephant flow
        expect(elephant_flow - top_k.list('users').keys).to be_empty
        # but the rest of the items in the list could be incorrect
        expect(calculate_accuracy(stream, top_k, size)).to be >= min_accuracy / 2
      end
    end

    context 'when stream is dominated by multiple elephant flows' do
      it 'correctly determines' do
        flows = {
          elephant_flow: size.times.map(&:to_s),
          mouse_flow: 1000.times.map { |i| (size + i).to_s }
        }

        stream = 10_000.times.map do
          chosen_flow = %i[elephant_flow mouse_flow].sample

          index = if chosen_flow == :mouse_flow
                    SecureRandom.random_number(1000)
                  else
                    SecureRandom.random_number(size)
                  end

          flows[chosen_flow][index]
        end

        # we have 256 slots (128 x 2) to store 1010 items
        top_k.reserve('users', top_k: size, width: 128, depth: 2, decay: 0.9)
        stream.each { |item| top_k.add('users', item) }

        difference = top_k.list('users').keys - flows[:elephant_flow]
        actual_accuracy = 1.0 - (difference.count.to_f / size)
        expect(actual_accuracy).to be >= min_accuracy
      end
    end

    context 'when stream is uniform' do
      it 'has low accuracy' do
        stream = 5000.times.flat_map { SecureRandom.random_number(100).to_s }

        # we have 256 slots (128 x 2) to store 100 items
        top_k.reserve('users', top_k: size, width: 128, depth: 2, decay: 0.9)
        stream.each { |item| top_k.add('users', item) }

        # the algorithm cannot determine the difference if the flows size are
        # identical from each other
        expect(calculate_accuracy(stream, top_k, size)).to be >= (min_accuracy / 2)
      end
    end
  end

  describe '#reserve' do
    let(:key) { 'users' }
    subject { top_k.reserve(key, options) }

    context 'when options are not provided' do
      let(:options) { {} }
      let(:message) { 'Top K is missing. Width is missing. Depth is missing. Decay is missing' }

      it 'raises error' do
        expect { subject }.to raise_error(HeavyKeeper::Error, message)
      end
    end

    context 'when options are provided with invalid value' do
      let(:options) do
        {
          top_k: 'abc',
          width: '1.9',
          depth: nil,
          decay: ['a']
        }
      end
      let(:message) { 'Top K must be an integer. Width must be an integer. Depth must be filled. Decay must be a decimal' }

      it 'raises error' do
        expect { subject }.to raise_error(HeavyKeeper::Error, message)
      end
    end

    context 'when options are provided with valid value' do
      let(:options) { { top_k: 10, width: 256, depth: 5, decay: 0.9 } }
      let(:data) { { 'top_k' => '10', 'width' => '256', 'depth' => '5', 'decay' => '0.9' } }

      it 'stores the options correctly' do
        expect { subject }.to change { redis.hgetall('cache_prefix_heavykeeper:users:data') }
          .from({}).to(data)
      end
    end
  end

  describe '#add' do
    let(:items) { 'item' }
    subject { top_k.add('users', *items) }

    context 'when metadata is not setup' do
      it 'raises error' do
        expect { subject }.to raise_error(HeavyKeeper::Error, 'Top K is missing. Width is missing. Depth is missing. Decay is missing')
      end
    end

    context 'when metadata is setup' do
      before { top_k.reserve('users', top_k: 1, width: 10, depth: 2, decay: 0.9) }

      it { is_expected.to eq [1] }
    end

    context 'when there are some items being dropped from the list' do
      let(:items) { ['item_2'] * 10 }

      before do
        top_k.reserve('users', top_k: 1, width: 10, depth: 2, decay: 0.9)
        top_k.add('users', 'item_1', 'item_1')
      end

      it { is_expected.to eq [nil, 2, 3, 4, 5, 6, 7, 8, 9, 10] }
    end
  end

  describe '#increase_by' do
    let(:items) { [['item', 1]] }
    subject { top_k.increase_by('users', *items) }

    context 'when metadata is not setup' do
      it 'raises error' do
        expect { subject }.to raise_error(HeavyKeeper::Error, 'Top K is missing. Width is missing. Depth is missing. Decay is missing')
      end
    end

    context 'when metadata is setup' do
      before { top_k.reserve('users', top_k: 1, width: 10, depth: 2, decay: 0.9) }

      it { is_expected.to eq [1] }
    end

    context 'when there are some items being dropped from the list' do
      let(:items) { [['item_3', 1], ['item_2', 10]] }

      before do
        top_k.reserve('users', top_k: 1, width: 10, depth: 2, decay: 0.9)
        top_k.increase_by('users', ['item_1', 2])
      end

      it { is_expected.to eq [nil, 10] }
    end

    context 'when an increment is not an integer' do
      let(:items) { [['item_1', 1], ['item_2', 1.5]] }

      before { top_k.reserve('users', top_k: 10, width: 10, depth: 2, decay: 0.9) }

      it 'raises error and writes nothing' do
        expect { subject }
          .to raise_error(HeavyKeeper::Error, 'Increment for "item_2" must be an integer, got 1.5')
          .and not_change { top_k.query('users', 'item_1') }
      end
    end

    context 'when there are several items' do
      let(:items) { [['item_1', 1], ['item_2', 2], ['item_3', 3]] }

      before { top_k.reserve('users', top_k: 10, width: 10, depth: 2, decay: 0.9) }

      it 'uses one HGETALL and one EVALSHA' do
        expect(redis).to receive(:hgetall).once.and_call_original
        expect(redis).to receive(:evalsha).once.and_call_original
        expect(redis).not_to receive(:hget)
        expect(redis).not_to receive(:hset)

        expect(subject).to eq [1, 2, 3]
      end
    end

    context 'when the items need more bucket updates than one script allows' do
      let(:items) { Array.new(10) { |i| ["item_#{i}", 1] } }

      before { top_k.reserve('users', top_k: 10, width: 2048, depth: 32, decay: 0.9) }

      it 'splits the items into more than one script' do
        # 256 bucket updates / depth 32 = 8 items for each script
        expect(redis).to receive(:evalsha).twice.and_call_original

        expect(subject).to eq [1] * 10
      end
    end

    context 'when Redis does not have the script in its cache' do
      before do
        top_k.reserve('users', top_k: 1, width: 10, depth: 2, decay: 0.9)
        redis.script(:flush)
      end

      it 'loads the script again with EVAL' do
        expect(redis).to receive(:eval).once.and_call_original

        expect(subject).to eq [1]
        expect(redis.script(:exists, described_class::INCREASE_BY_SHA)).to be true
      end
    end

    context 'when the buckets hold data from version 0.1.6' do
      let(:item) { 'item' }
      let(:fingerprint) { XXhash.xxh64(item) }
      let(:items) { [[item, 1]] }
      let(:bucket) { HeavyKeeper::Bucket.new(redis) }

      before do
        top_k.reserve('users', top_k: 1, width: 1, depth: 1, decay: 0.9)
        # Data as written by the Ruby implementation before 0.2.0
        bucket.set('users', 0, 0, [fingerprint, 5])
        heap = HeavyKeeper::MinHeap.new(redis)
        redis.zadd(heap.sorted_set_key('users'), 5, item)
        redis.hset(heap.hash_key('users'), item, 5)
      end

      it 'reads and updates the bucket in the same format' do
        # Lua numbers cannot hold this fingerprint exactly
        expect(fingerprint).to be > 2**53

        expect(subject).to eq [6]
        expect(redis.hget(bucket.hash_key('users'), '0:0')).to eq JSON.generate([fingerprint, 6])
      end
    end

    context 'when another item holds the bucket' do
      let(:bucket) { HeavyKeeper::Bucket.new(redis) }
      let(:items) { [['item_b', 1]] }

      before do
        top_k.reserve('users', top_k: 2, width: 1, depth: 1, decay: decay)
        top_k.increase_by('users', ['item_a', count])
      end

      context 'when the decay always happens' do
        # decay ^ count = 1, and every random number is below 1
        let(:decay) { 1.0 }
        let(:count) { 1 }

        it 'decays the other item and takes the bucket' do
          expect(subject).to eq [1]
          expect(bucket.get('users', 0, 0)).to eq [XXhash.xxh64('item_b'), 1]
        end
      end

      context 'when the decay almost never happens' do
        # decay ^ count is about 1.7e-46
        let(:decay) { 0.9 }
        let(:count) { 1_000 }

        it 'keeps the bucket of the other item' do
          expect(subject).to eq [0]
          expect(bucket.get('users', 0, 0)).to eq [XXhash.xxh64('item_a'), 1_000]
        end
      end
    end

    context 'when several clients write at the same time' do
      let(:heap) { HeavyKeeper::MinHeap.new(redis) }

      def write_concurrently(threads:, &block)
        Array.new(threads) do |t|
          Thread.new do
            client = Redis.new
            block.call(described_class.new(storage: client), t)
          ensure
            client&.close
          end
        end.each(&:join)
      end

      it 'does not lose updates' do
        top_k.reserve('users', top_k: 10, width: 10, depth: 2, decay: 0.9)

        write_concurrently(threads: 5) do |client_top_k, _|
          50.times { client_top_k.add('users', 'item') }
        end

        expect(top_k.count('users', 'item')).to eq [250]
      end

      it 'keeps the min-heap within top_k' do
        top_k.reserve('users', top_k: 5, width: 16, depth: 2, decay: 0.9)

        write_concurrently(threads: 5) do |client_top_k, t|
          40.times { |i| client_top_k.add('users', "item_#{t}_#{i}") }
        end

        members = redis.zrange(heap.sorted_set_key('users'), 0, -1)
        expect(members.size).to eq 5
        expect(redis.hkeys(heap.hash_key('users'))).to match_array(members)
      end
    end
  end

  describe '#remove' do
    let(:item) { 'item' }

    subject { top_k.remove('users', item) }

    context 'when metadata is not setup' do
      it 'raises error' do
        expect {
          subject
        }.to raise_error(
          HeavyKeeper::Error,
          'Top K is missing. Width is missing. Depth is missing. Decay is missing'
        )
      end
    end

    context 'when fingerprint is matched' do
      before do
        top_k.reserve('users', top_k: 1, width: 10, depth: 1, decay: 0.9)
        top_k.increase_by('users', ['item', 10], ['another_item', 10])
      end

      it 'reset the counter successfully' do
        expect {
          subject
        }.to change { top_k.query('users', 'item').first }
          .from(true).to(false)
          .and change { top_k.count('users', 'item').first }
          .from(10).to(0)
          .and not_change { top_k.query('users', 'another_item') }
      end
    end

    context 'when fingerprint is mismatched' do
      before do
        top_k.reserve('users', top_k: 1, width: 1, depth: 1, decay: 0.9)
        top_k.increase_by('users', ['another_item', 10])
      end

      it 'does not affect current data' do
        expect {
          subject
        }.to not_change { top_k.count('users', 'another_item') }
          .and not_change { top_k.query('users', 'another_item') }
      end
    end
  end

  describe '#query' do
    let(:items) { 'item' }
    subject { top_k.query('users', *items) }

    context 'when item does not exist' do
      it { is_expected.to eq [false] }
    end

    context 'when item exists' do
      let(:items) { %w[item item_x] }

      before do
        top_k.reserve('users', top_k: 1, width: 10, depth: 2, decay: 0.9)
        top_k.increase_by('users', ['item', 10])
      end

      it { is_expected.to eq [true, false] }
    end
  end

  describe '#count' do
    let(:items) { 'item' }
    subject { top_k.count('users', *items) }

    context 'when item does not exist' do
      it { is_expected.to eq [0] }
    end

    context 'when item exists' do
      let(:items) { %w[item item_x] }

      before do
        top_k.reserve('users', top_k: 1, width: 10, depth: 2, decay: 0.9)
        top_k.increase_by('users', ['item', 10])
      end

      it { is_expected.to eq [10, 0] }
    end
  end

  describe '#list' do
    subject { top_k.list('users') }

    context 'when there is no item' do
      it { is_expected.to eq({}) }
    end

    context 'when item exists' do
      before do
        top_k.reserve('users', top_k: 1, width: 10, depth: 2, decay: 0.9)
        top_k.increase_by('users', ['item', 10])
      end

      it { is_expected.to eq({ 'item' => '10' }) }
    end
  end

  describe '#clear' do
    context 'when there is no data' do
      it 'returns success' do
        top_k.clear('users')
      end
    end

    context 'when item exists' do
      before do
        top_k.reserve('users', top_k: 1, width: 10, depth: 2, decay: 0.9)
        top_k.increase_by('users', ['item', 10])
      end

      it 'returns success' do
        expect {
          top_k.clear('users')
        }.to change { top_k.query('users', 'item') }
          .from([true]).to([false])
      end

      it 'deletes all keys in one transaction' do
        exec_calls = -> { redis.info('commandstats').dig('exec', 'calls').to_i }

        expect {
          top_k.clear('users')
        }.to change { exec_calls.call }.by(1)
          .and change { redis.keys('*').size }.from(4).to(0)
      end
    end
  end
end
