require 'spec_helper'
require Arachni::Options.paths.lib + 'rpc/server/base'
require Arachni::Options.paths.lib + 'rpc/server/framework'

class Distributor
    include Arachni::RPC::Server::Framework::Distributor

    attr_reader   :slaves
    attr_reader   :done_slaves
    attr_accessor :master_url

    [ :map_slaves, :each_slave, :slave_iterator, :iterator_for,
      :preferred_dispatchers, :pick_dispatchers, :prepare_slave_options,
      :split_page_workload, :calculate_workload_size ].each do |sym|
        private sym
        public sym
    end

    def initialize( token )
        @opts        = Arachni::Options.instance
        @local_token = token
        @slaves      = []
        @done_slaves = Set.new
    end

    def state
        Arachni::State
    end

    def slave_done?( url )
        @done_slaves.include? url
    end

    def dispatcher_url=( url )
        @opts.datastore.dispatcher_url = url
    end

    def <<( instance_h )
        @slaves << instance_h
    end
end

class FakeMaster

    attr_reader :issues

    def initialize( opts, token )
        @opts  = opts
        @token = token
        @server = Arachni::RPC::Server::Base.new( @opts, token )

        @pages  = []
        @issues = []
        @element_ids     = []

        @server.add_handler( 'framework', self )
        @server.start
    end

    def enslave( instance_hash )
        instance = Arachni::RPC::Client::Instance.new( @opts,
                                                       instance_hash[:url],
                                                       instance_hash[:token])

        instance.framework.
            set_master( "#{@server.opts[:host]}:#{@server.opts[:port]}", @token )
    end

    def slave_sitrep( data, url, token = nil )
        return false if !valid_token?( token )
        @issues |= data[:issues] || []
        true
    end

    private

    def valid_token?( token )
        @token == token
    end

end

describe Arachni::RPC::Server::Framework::Distributor do

    def get_distributor
        distributor = Distributor.new( @token )
        2.times {
            instance = instance_spawn
            distributor <<  {
                url:   instance.url,
                token: instance_token_for( instance.url )
            }
        }
        distributor
    end

    before( :all ) do
        @opts             = Arachni::Options.instance
        @opts.audit.links = true
        @opts.audit.forms = true
        @token            = 'secret'

        @distributor = get_distributor

        @url = 'http://test.com/'
    end

    describe '#calculate_workload_size' do
        it 'returns the amount of workload to gather for distribution' do
            @distributor.calculate_workload_size( 99999 ).should == 30
        end

        it 'bases it on the amount of idle instances' do
            distributor = get_distributor
            distributor.done_slaves << distributor.slaves.first[:url]
            distributor.calculate_workload_size( 99999 ).should == 20
        end

        context 'when the calculated size exceeds the maximum' do
            it 'returns the maximum' do
                @distributor.calculate_workload_size( 20 ).should == 20
            end
        end
    end

    describe '#split_page_workload' do
        let(:pages) do
            pages = []

            url = "#{@url}/1"
            pages << Arachni::Page.from_data(
                url: url,
                forms: [
                         Arachni::Form.new( url: url, inputs: { test: 1 } ),
                         Arachni::Form.new(
                             url: url,
                             action: "#{url}/my-action",
                             inputs: { test: 1 }
                         )
                     ]
            )

            url = "#{@url}/2"
            pages << Arachni::Page.from_data(
                url: url,
                forms: [
                         Arachni::Form.new( url: "#{@url}/1", inputs: { test: 1 } ),
                         Arachni::Form.new(
                             url: url,
                             action: "#{url}/my-action2",
                             inputs: { test: 1 }
                         )
                     ]
            )

            url = "#{@url}/3"
            pages << Arachni::Page.from_data(
                url: url,
                forms: [
                         Arachni::Form.new( url: "#{@url}/2", inputs: { test: 1 } ),
                         Arachni::Form.new(
                             url: url,
                             action: "#{url}/my-action2",
                             inputs: { test: 1 }
                         )
                     ]
            )

            url = "#{@url}/4"
            pages << Arachni::Page.from_data(
                url: url,
                forms: [
                         Arachni::Form.new( url: url, inputs: { test: 1 } ),
                         Arachni::Form.new(
                             url: url,
                             action: "#{url}/my-action",
                             inputs: { test: 1 }
                         )
                     ]
            )

            url = "#{@url}/5"
            pages << Arachni::Page.from_data(
                url: url,
                forms: [
                         Arachni::Form.new(
                             url: url,
                             action: "#{url}/my-action",
                             inputs: { test: 1 }
                         )
                     ]
            )
            pages
        end

        context 'when there are new pages' do
            context 'with new elements' do
                it 'splits the workload for the available instances' do
                    distributor = get_distributor

                    workload = []
                    distributor.split_page_workload( pages ).map do |page_chunks|
                        workload << Hash[page_chunks.map { |p| [p.url, p.element_audit_whitelist.to_a] }]
                    end
                    workload.should == [
                        {
                            "#{@url}1" => [2720541242, 3706493238],
                            "#{@url}2" => [2299786370]
                        },
                        {
                            "#{@url}3" => [3008708675, 1846432277],
                            "#{@url}4" => [2444203185] },
                        {
                            "#{@url}4" => [2195342275],
                            "#{@url}5" => [659674061]
                        }
                    ]

                    Arachni::State.clear

                    distributor = get_distributor
                    # Mark one of the instances as done.
                    distributor.done_slaves << distributor.slaves.first[:url]

                    workload = []
                    distributor.split_page_workload( pages ).map do |page_chunks|
                        workload << Hash[page_chunks.map { |p| [p.url, p.element_audit_whitelist.to_a] }]
                    end
                    workload.should == [
                        {
                            'http://test.com/1' => [2720541242, 3706493238],
                            'http://test.com/2' => [2299786370],
                            'http://test.com/3' => [3008708675]
                        },
                        {
                            'http://test.com/3' => [1846432277],
                            'http://test.com/4' => [2444203185, 2195342275],
                            'http://test.com/5' => [659674061]
                        }
                    ]
                end
            end

            context 'with seen elements' do
                it 'distributes them as is' do
                    distributor = get_distributor
                    distributor.split_page_workload( pages )

                    pages.each do |page|
                        page.body << 'stuff'
                    end

                    workload = []
                    distributor.split_page_workload( pages ).map do |page_chunks|
                        workload << page_chunks.map(&:url)
                    end
                    workload.should == [
                        ['http://test.com/1', 'http://test.com/2'],
                        ['http://test.com/3', 'http://test.com/4'],
                        ['http://test.com/5']
                    ]
                end

                it 'does not audit them' do
                    distributor = get_distributor
                    distributor.split_page_workload( pages )

                    pages.each do |page|
                        page.body << 'stuff'
                    end

                    workload = []
                    distributor.split_page_workload( pages ).map do |page_chunks|
                        workload << page_chunks
                    end
                    workload.flatten!
                    workload.size.should == 5

                    workload.each do |page|
                        page.elements.should be_any
                        page.elements.each { |e| page.audit_element?(e).should be_false }
                    end
                end
            end

            context 'without any elements' do
                it 'distributes them as is' do
                    pages = []

                    20.times do |i|
                        pages << Arachni::Page.from_data( url: "#{@url}/#{i}", body: i.to_s )
                    end

                    workload = []
                    get_distributor.split_page_workload( pages ).map do |page_chunks|
                        workload << page_chunks.map(&:url)
                    end
                    workload.should == [
                        [
                            'http://test.com/0',
                            'http://test.com/1',
                            'http://test.com/2',
                            'http://test.com/3',
                            'http://test.com/4',
                            'http://test.com/5',
                            'http://test.com/6'
                        ],
                        [
                            'http://test.com/7',
                            'http://test.com/8',
                            'http://test.com/9',
                            'http://test.com/10',
                            'http://test.com/11',
                            'http://test.com/12',
                            'http://test.com/13'
                        ],
                        [
                            'http://test.com/14',
                            'http://test.com/15',
                            'http://test.com/16',
                            'http://test.com/17',
                            'http://test.com/18',
                            'http://test.com/19'
                        ]
                    ]
                end
            end
        end

        context 'when there are seen pages' do
            context 'with new elements' do
                it 'only distributes new elements' do
                    distributor = get_distributor
                    distributor.split_page_workload( pages )

                    pages.first.forms |= [
                        Arachni::Form.new(
                            url:    pages.first.url,
                            action: "#{pages.first.url}/my-action",
                            inputs: { tes2: 1 }
                        )
                    ]

                    pages.last.forms |= [
                        Arachni::Form.new(
                            url:    pages.last.url,
                            action: "#{pages.last.url}/my-action",
                            inputs: { tes2: 1 }
                        )
                    ]

                    workload = []
                    distributor.split_page_workload( pages ).map do |page_chunks|
                        workload << Hash[page_chunks.map { |p| [p.url, p.element_audit_whitelist.to_a] }]
                    end

                    workload.should == [
                        { 'http://test.com/1' => [2835048516] },
                        { 'http://test.com/5' => [1397105343] }
                    ]
                end
            end

            context 'with seen elements' do
                it 'return an empty array' do
                    distributor = get_distributor

                    distributor.split_page_workload( pages )

                    workload = []
                    distributor.split_page_workload( pages ).map do |page_chunks|
                        workload << Hash[page_chunks.map { |p| [p.url, p.audit_whitelist.to_a] }]
                    end
                    workload.should == []
                end
            end
        end
    end

    describe '#prepare_slave_options' do
        it 'returns a hash with options suitable for passing to slaves' do
            @distributor.prepare_slave_options.should == {
                http:      {
                    user_agent:             @opts.http.user_agent,
                    request_timeout:        50000,
                    request_redirect_limit: 5,
                    request_concurrency:    20,
                    request_queue_size:     500,
                    request_headers:        {},
                    cookies:                {}
                },
                audit:     {
                    exclude_vectors: [],
                    links:           true,
                    forms:           true
                },
                login:     {},
                datastore: {
                    master_priv_token: 'secret'
                },
                output:    {},
                scope:     {
                    redundant_path_patterns: {},
                    dom_depth_limit:         10,
                    exclude_path_patterns:   [],
                    exclude_page_patterns:   [],
                    include_path_patterns:   [],
                    restrict_paths:          [],
                    extend_paths:            []
                },
                checks:    [],
                platforms: [],
                reports:   {},
                plugins:   {},
                no_fingerprinting: false,
                authorized_by:     nil,
                browser_cluster: {
                    pool_size:           6,
                    job_timeout:         50,
                    worker_time_to_live: 100,
                    ignore_images:       false
                }
            }
        end
    end

    describe '#map_slaves' do
        it 'asynchronously maps all slaves' do
            q = Queue.new

            foreach = proc { |instance, iter| instance.service.alive? { |res| iter.return( res ) } }
            after = proc { |res| q << res }

            @distributor.map_slaves( foreach, after )

            raised = false
            begin
                Timeout::timeout( 5 ) { q.pop.should == [true, true] }
            rescue Timeout::Error
                raised = true
            end
            raised.should be_false
        end
    end

    describe '#each_slave' do
        it 'asynchronously iterates over all slaves' do
            q = Queue.new

            foreach = proc do |instance, iter|
                instance.service.alive? do |res|
                    q << res
                    iter.next
                end
            end
            @distributor.each_slave( &foreach )

            raised = false
            begin
                Timeout::timeout( 5 ) { [q.pop, q.pop].should == [true, true] }
            rescue Timeout::Error
                raised = true
            end
            raised.should be_false
        end

        context 'when passed an "after" block' do
            it 'calls it after the iteration has completed' do
                q = Queue.new

                foreach = proc do |instance, iter|
                    instance.service.alive? do |res|
                        q << res
                        iter.next
                    end
                end
                after = proc { q << :after }

                @distributor.each_slave( foreach, after )

                raised = false
                begin
                    Timeout::timeout( 5 ) { [q.pop, q.pop, q.pop].should == [true, true, :after] }
                rescue Timeout::Error
                    raised = true
                end
                raised.should be_false
            end

        end
    end

    describe '#slave_iterator' do
        it 'returns an async iterator for the slave instances' do
            q = Queue.new

            foreach = proc do |instance, iter|
                q << instance['url']
                iter.next
            end
            @distributor.slave_iterator.each( &foreach )

            urls = @distributor.slaves.map { |i| i['url'] }.sort

            raised = false
            begin
                Timeout::timeout( 5 ) { [q.pop, q.pop].sort.should == urls }
            rescue Timeout::Error
                raised = true
            end
            raised.should be_false
        end
    end

    describe '#iterator_for' do
        it 'returns an async iterator for the provided array' do
            q = Queue.new

            foreach = proc do |instance, iter|
                q << instance['url']
                iter.next
            end
            @distributor.iterator_for( @distributor.slaves ).each( &foreach )

            urls = @distributor.slaves.map { |i| i['url'] }.sort

            raised = false
            begin
                Timeout::timeout( 5 ) { [q.pop, q.pop].sort.should == urls }
            rescue Timeout::Error
                raised = true
            end
            raised.should be_false
        end
    end

    describe '#preferred_dispatchers' do
        it 'returns a sorted list of dispatchers for HPG use taking into account their pipe IDs and load balancing metrics' do
            dispatchers = []


            d1 = dispatcher_light_spawn

            dispatchers << dispatcher_light_spawn(
                pipe_id: '1',
                neighbour: d1.url
            ).url

            dispatchers << dispatcher_light_spawn(
                pipe_id:   '3',
                neighbour: d1.url
            ).url

            dispatcher_light_spawn(
                weight:  3,
                pipe_id: '1',
                neighbour: d1.url
            )

            dispatchers << dispatcher_light_spawn(
                weight:    3,
                pipe_id:   '2',
                neighbour: d1.url
            ).url

            dispatcher_light_spawn(
                weight:    2,
                pipe_id:   '3',
                neighbour: d1.url
            )

            dispatchers << dispatcher_light_spawn(
                weight:    4,
                pipe_id:   '4',
                neighbour: d1.url
            ).url

            @distributor.dispatcher_url = d1.url

            q = Queue.new
            @distributor.preferred_dispatchers { |d| q << d }

            pref_dispatchers = []

            raised = false
            begin
                Timeout.timeout( 10 ) { pref_dispatchers = q.pop }
            rescue TimeoutError
                raised = true
            end

            raised.should be_false

            pref_dispatchers.size.should == 4
            pref_dispatchers.should == dispatchers
        end
    end

    describe '#pick_dispatchers' do
        it 'returns a sorted list of dispatchers based on their load balancing metrics' do
            dispatchers = []
            dispatchers << { 'node' => { 'score' => 0 } }
            dispatchers << { 'node' => { 'score' => 3 } }
            dispatchers << { 'node' => { 'score' => 2 } }
            dispatchers << { 'node' => { 'score' => 1 } }

            @distributor.pick_dispatchers( dispatchers ).
                map { |d| d['node']['score'] }.should == [0, 1, 2, 3]

            @opts.spawns = 2
            @distributor.pick_dispatchers( dispatchers ).
                map { |d| d['node']['score'] }.should == [0, 1]
        end
    end

    describe '#initialize_slaves' do
        #before( :all ) do
        #    @opts.paths.checks = fixtures_path + 'taint_check/'
        #
        #    @dispatcher_url = dispatcher_light_spawn.url
        #
        #    @opts.rpc.server_port   = available_port
        #    @master                 = FakeMaster.new( @opts, @token )
        #    @distributor.master_url = "#{@opts.rpc.server_address}:#{@opts.rpc.server_port}"
        #
        #    # master's token
        #    @opts.datastore.token = @token
        #    @opts.url             = web_server_url_for( :framework_hpg )
        #    @url                  = @opts.url
        #    @opts.checks          = %w(taint)
        #
        #    @get_instance_info = proc do
        #        instance = instance_spawn( token: @token, port: nil )
        #        info = {
        #            'url'   => instance.url,
        #            'token' => instance_token_for( instance )
        #        }
        #        @master.enslave( info )
        #        info
        #    end
        #end
        #
        #after do
        #    @master.issues.clear
        #end
    end

end
