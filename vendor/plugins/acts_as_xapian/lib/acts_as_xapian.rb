# acts_as_xapian/lib/acts_as_xapian.rb:
# Xapian full text search in Ruby on Rails.
#
# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: acts_as_xapian.rb,v 1.25 2008-05-18 18:56:21 francis Exp $

# Documentation
# =============
#
# See ../README.txt for documentation. Please update that file if you edit
# code.

require 'xapian'

module ActsAsXapian
    ######################################################################
    # Module level variables
    # XXX must be some kind of cattr_accessor that can do this better
    def ActsAsXapian.db_path
        @@db_path
    end
    # XXX global class intializers here get loaded more than once, don't know why. Protect them.
    if not $acts_as_xapian_class_var_init 
        @@db = nil
        @@writable_db = nil
        @@writable_suffix = nil
        @@init_values = []
        $acts_as_xapian_class_var_init = true
    end
    def ActsAsXapian.db
        @@db
    end
    def ActsAsXapian.writable_db
        @@writable_db
    end
    def ActsAsXapian.stemmer
        @@stemmer
    end
    def ActsAsXapian.term_generator
        @@term_generator
    end
    def ActsAsXapian.enquire
        @@enquire
    end
    def ActsAsXapian.query_parser
        @@query_parser
    end
    def ActsAsXapian.values_by_prefix
        @@values_by_prefix
    end

    ######################################################################
    # Initialisation
    def ActsAsXapian.init(classname = nil, options = nil)
        if not classname.nil?
            # store class and options for use later, when we open the db in readable_init
            @@init_values.push([classname,options])
        end

        # make the directory for the xapian databases to go in
        db_parent_path = File.join(File.dirname(__FILE__), '../xapiandbs/')
        Dir.mkdir(db_parent_path) unless File.exists?(db_parent_path)
        raise "Set RAILS_ENV, so acts_as_xapian can find the right Xapian database" if not ENV['RAILS_ENV']
        @@db_path = File.join(db_parent_path, ENV['RAILS_ENV']) 

        # make some things that don't depend on the db
        # XXX this gets made once for each acts_as_xapian. Oh well.
        @@stemmer = Xapian::Stem.new('english')
    end

    # Opens / reopens the db for reading
    # XXX we perhaps don't need to rebuild database and enquire and queryparser - 
    # but db.reopen wasn't enough by itself, so just do everything it's easier.
    def ActsAsXapian.readable_init
        # basic Xapian objects
        begin
            @@db = Xapian::Database.new(@@db_path)
            @@enquire = Xapian::Enquire.new(@@db)
        rescue IOError
            raise "Xapian database not opened; have you built it with scripts/rebuild-xapian-index ?"
        end

        init_query_parser
    end

    # Make a new query parser
    def ActsAsXapian.init_query_parser
        # for queries
        @@query_parser = Xapian::QueryParser.new
        @@query_parser.stemmer = @@stemmer
        @@query_parser.stemming_strategy = Xapian::QueryParser::STEM_SOME
        @@query_parser.database = @@db
        @@query_parser.default_op = Xapian::Query::OP_AND

        @@terms_by_capital = {}
        @@values_by_number = {}
        @@values_by_prefix = {}
        @@value_ranges_store = []

        for init_value_pair in @@init_values
            classname = init_value_pair[0]
            options = init_value_pair[1]

            # go through the various field types, and tell query parser about them,
            # and error check them - i.e. check for consistency between models
            @@query_parser.add_boolean_prefix("model", "M")
            @@query_parser.add_boolean_prefix("modelid", "I")
            if options[:terms]
              for term in options[:terms]
                  raise "Use a single capital letter for term code" if not term[1].match(/^[A-Z]$/)
                  raise "M and I are reserved for use as the model/id term" if term[1] == "M" or term[1] == "I"
                  raise "model and modelid are reserved for use as the model/id prefixes" if term[2] == "model" or term[2] == "modelid"
                  raise "Z is reserved for stemming terms" if term[1] == "Z"
                  raise "Already have code '" + term[1] + "' in another model but with different prefix '" + @@terms_by_capital[term[1]] + "'" if @@terms_by_capital.include?(term[1]) && @@terms_by_capital[term[1]] != term[2]
                  @@terms_by_capital[term[1]] = term[2]
                  @@query_parser.add_boolean_prefix(term[2], term[1])
              end
            end
            if options[:values]
              for value in options[:values]
                  raise "Value index '"+value[1].to_s+"' must be an integer, is " + value[1].class.to_s if value[1].class != 1.class
                  raise "Already have value index '" + value[1].to_s + "' in another model but with different prefix '" + @@values_by_number[value[1]].to_s + "'" if @@values_by_number.include?(value[1]) && @@values_by_number[value[1]] != value[2]

                  # date types are special, mark them so the first model they're seen for
                  if !@@values_by_number.include?(value[1])
                      if value[3] == :date 
                          value_range = Xapian::DateValueRangeProcessor.new(value[1])
                      elsif value[3] == :string 
                          value_range = Xapian::StringValueRangeProcessor.new(value[1])
                      elsif value[3] == :number
                          value_range = Xapian::NumberValueRangeProcessor.new(value[1])
                      else
                          raise "Unknown value type '" + value[3].to_s + "'"
                      end

                      @@query_parser.add_valuerangeprocessor(value_range)

                      # stop it being garbage collected, as
                      # add_valuerangeprocessor ref is outside Ruby's GC
                      @@value_ranges_store.push(value_range) 
                  end

                  @@values_by_number[value[1]] = value[2]
                  @@values_by_prefix[value[2]] = value[1]
              end
            end
        end
    end

    def ActsAsXapian.writable_init(suffix = "")
        ActsAsXapian.init # XXX so db_path is made

        new_path = @@db_path + suffix
        raise "writable_suffix/suffix inconsistency" if @@writable_suffix && @@writable_suffix != suffix
        if @@writable_db.nil?
            # for indexing
            @@writable_db = Xapian::WritableDatabase.new(new_path, Xapian::DB_CREATE_OR_OPEN)
            @@term_generator = Xapian::TermGenerator.new()
            @@term_generator.set_flags(Xapian::TermGenerator::FLAG_SPELLING, 0)
            @@term_generator.database = @@writable_db
            @@term_generator.stemmer = @@stemmer
            @@writable_suffix = suffix
        end
    end

    ######################################################################
    # Search with a query or for similar models
    
    # Base class for Search and Similar below
    class QueryBase
        attr_accessor :offset
        attr_accessor :limit
        attr_accessor :query
        attr_accessor :matches
        attr_accessor :query_models

        def initialize_db
            ActsAsXapian.readable_init
            if ActsAsXapian.db.nil?
                raise "ActsAsXapian not initialized"
            end
        end

        # Set self.query before calling this
        def initialize_query(options)
            #raise options.to_yaml
            offset = options[:offset] || 0; offset = offset.to_i
            limit = options[:limit] || 10; limit = limit.to_i
            sort_by_prefix = options[:sort_by_prefix] || nil
            sort_by_ascending = options[:sort_by_ascending] || true
            collapse_by_prefix = options[:collapse_by_prefix] || nil

            ActsAsXapian.enquire.query = self.query

            if sort_by_prefix.nil?
                ActsAsXapian.enquire.sort_by_relevance!
            else
                value = ActsAsXapian.values_by_prefix[sort_by_prefix]
                raise "couldn't find prefix '" + sort_by_prefix + "'" if value.nil?
                ActsAsXapian.enquire.sort_by_value_then_relevance!(value, sort_by_ascending)
            end
            if collapse_by_prefix.nil?
                ActsAsXapian.enquire.collapse_key = Xapian.BAD_VALUENO
            else
                value = ActsAsXapian.values_by_prefix[collapse_by_prefix]
                raise "couldn't find prefix '" + collapse_by_prefix + "'" if value.nil?
                ActsAsXapian.enquire.collapse_key = value
            end

            self.matches = ActsAsXapian.enquire.mset(offset, limit, 100)
        end

        # Return a description of the query
        def description
            self.query.description
        end

        # Estimate total number of results
        def matches_estimated
            self.matches.matches_estimated
        end

        # Return query string with spelling correction
        def spelling_correction
            correction = ActsAsXapian.query_parser.get_corrected_query_string
            if correction.empty?
                return nil
            end
            return correction
        end

        # Return array of models found
        def results
            # Pull out all the results
            docs = []
            iter = self.matches._begin
            while not iter.equals(self.matches._end)
                docs.push({:data => iter.document.data, 
                        :percent => iter.percent, 
                        :weight => iter.weight,
                        :collapse_count => iter.collapse_count})
                iter.next
            end

            # Look up without too many SQL queries
            lhash = {}
            lhash.default = []
            for doc in docs
                k = doc[:data].split('-')
                lhash[k[0]] = lhash[k[0]] + [k[1]]
            end
            # for each class, look up all ids
            chash = {}
            for cls, ids in lhash
                conditions = [ "#{cls.constantize.table_name}.id in (?)", ids ]
                found = cls.constantize.find(:all, :conditions => conditions, :include => cls.constantize.xapian_options[:eager_load])
                for f in found
                    chash[[cls, f.id]] = f
                end
            end
            # now get them in right order again
            results = []
            docs.each{|doc| k = doc[:data].split('-'); results << { :model => chash[[k[0], k[1].to_i]],
                    :percent => doc[:percent], :weight => doc[:weight], :collapse_count => doc[:collapse_count] } }
            return results
        end
    end

    # Search for a query string, returns an array of hashes in result order.
    # Each hash contains the actual Rails object in :model, and other detail
    # about relevancy etc. in other keys.
    class Search < QueryBase
        attr_accessor :query_string

        # Note that model_classes is not only sometimes useful here - it's
        # essential to make sure the classes have been loaded, and thus
        # acts_as_xapian called on them, so we know the fields for the query
        # parser.
        
        # model_classes - model classes to search within, e.g. [PublicBody, User]
        # query_string - user inputed query string, with syntax much like Google Search
        def initialize(model_classes, query_string, options = {})
            self.initialize_db

            # Case of a string, searching for a Google-like syntax query
            self.query_string = query_string

            # Construct query which only finds things from specified models
            model_query = Xapian::Query.new(Xapian::Query::OP_OR, model_classes.map{|mc| "M" + mc.to_s})
            user_query = ActsAsXapian.query_parser.parse_query(self.query_string,
                  Xapian::QueryParser::FLAG_BOOLEAN | Xapian::QueryParser::FLAG_PHRASE |
                  Xapian::QueryParser::FLAG_LOVEHATE | Xapian::QueryParser::FLAG_WILDCARD |
                  Xapian::QueryParser::FLAG_SPELLING_CORRECTION)
            self.query = Xapian::Query.new(Xapian::Query::OP_AND, model_query, user_query)

            # Call base class constructor
            self.initialize_query(options)
        end

        # Return just normal words in the query i.e. Not operators, ones in
        # date ranges or similar. Use this for cheap highlighting with
        # TextHelper::highlight, and excerpt.
        def words_to_highlight
            query_nopunc = self.query_string.gsub(/[^a-z0-9:\.\/_]/i, " ")
            query_nopunc = query_nopunc.gsub(/\s+/, " ")
            words = query_nopunc.split(" ")
            # Remove anything with a :, . or / in it
            words = words.find_all {|o| !o.match(/(:|\.|\/)/) }
            words = words.find_all {|o| !o.match(/^(AND|NOT|OR|XOR)$/) }
            return words
        end

    end

    # Search for models which contain theimportant terms taken from a specified
    # list of models. i.e. Use to find documents similar to one (or more)
    # documents, or use to refine searches.
    class Similar < QueryBase
        attr_accessor :query_models
        attr_accessor :important_terms

        # model_classes - model classes to search within, e.g. [PublicBody, User]
        # query_models - list of models you want to find things similar to
        def initialize(model_classes, query_models, options = {})
            self.initialize_db

            # Case of an array, searching for models similar to those models in the array
            self.query_models = query_models

            # Find the documents by their unique term
            input_models_query = Xapian::Query.new(Xapian::Query::OP_OR, query_models.map{|m| "I" + m.xapian_document_term})
            ActsAsXapian.enquire.query = input_models_query
            matches = ActsAsXapian.enquire.mset(0, 100, 100) # XXX so this whole method will only work with 100 docs

            # Get set of relevant terms for those documents
            selection = Xapian::RSet.new()
            iter = matches._begin
            while not iter.equals(matches._end)
                selection.add_document(iter)
                iter.next
            end

            # Bit weird that the function to make esets is part of the enquire
            # object. This explains what exactly it does, which is to exclude
            # terms in the existing query.
            # http://thread.gmane.org/gmane.comp.search.xapian.general/3673/focus=3681
            eset = ActsAsXapian.enquire.eset(40, selection) 

            # Do main search for them
            self.important_terms = []
            iter = eset._begin
            while not iter.equals(eset._end)
                self.important_terms.push(iter.term)
                iter.next
            end
            similar_query = Xapian::Query.new(Xapian::Query::OP_OR, self.important_terms)
            # Exclude original
            combined_query = Xapian::Query.new(Xapian::Query::OP_AND_NOT, similar_query, input_models_query)

            # Restrain to model classes
            model_query = Xapian::Query.new(Xapian::Query::OP_OR, model_classes.map{|mc| "M" + mc.to_s})
            self.query = Xapian::Query.new(Xapian::Query::OP_AND, model_query, combined_query)

            # Call base class constructor
            self.initialize_query(options)
        end
    end

    ######################################################################
    # Index
   
    # Offline indexing job queue model, create with migration made 
    # using "script/generate acts_as_xapian" as described in ../README.txt
    class ActsAsXapianJob < ActiveRecord::Base
    end

    # Update index with any changes needed, call this offline. Only call it
    # from a script that exits - otherwise Xapian's writable database won't
    # flush your changes. Specifying flush will reduce performance, but 
    # make sure that each index update is definitely saved to disk before
    # logging in the database that it has been.
    def ActsAsXapian.update_index(flush = false)
        ActsAsXapian.writable_init

        ids_to_refresh = ActsAsXapianJob.find(:all).map() { |i| i.id }
        for id in ids_to_refresh
            ActiveRecord::Base.transaction do
                job = ActsAsXapianJob.find(id, :lock =>true)
                if job.action == 'update'
                    # XXX Index functions may reference other models, so we could eager load here too?
                    model = job.model.constantize.find(job.model_id) # :include => cls.constantize.xapian_options[:include]
                    model.xapian_index
                elsif job.action == 'destroy'
                    # Make dummy model with right id, just for destruction
                    model = job.model.constantize.new
                    model.id = job.model_id
                    model.xapian_destroy
                else
                    raise "unknown ActsAsXapianJob action '" + job.action + "'"
                end
                job.destroy

                if flush
                    ActsAsXapian.writable_db.flush
                end
            end
        end
    end
        
    # You must specify *all* the models here, this totally rebuilds the Xapian database.
    # You'll want any readers to reopen the database after this.
    def ActsAsXapian.rebuild_index(model_classes)
        raise "when rebuilding all, please call as first and only thing done in process / task" if not ActsAsXapian.writable_db.nil?

        # Delete any existing .new database, and open a new one
        new_path = ActsAsXapian.db_path + ".new"
        if File.exist?(new_path)
            raise "found existing " + new_path + " which is not Xapian flint database, please delete for me" if not File.exist?(File.join(new_path, "iamflint"))
            FileUtils.rm_r(new_path)
        end
        ActsAsXapian.writable_init(".new")

        # Index everything 
        ActsAsXapianJob.destroy_all
        for model_class in model_classes
            models = model_class.find(:all)
            for model in models
                model.xapian_index
            end
        end
        ActsAsXapian.writable_db.flush

        # Rename into place
        old_path = ActsAsXapian.db_path
        temp_path = ActsAsXapian.db_path + ".tmp"
        if File.exist?(temp_path)
            raise "temporary database found " + temp_path + " which is not Xapian flint database, please delete for me" if not File.exist?(File.join(temp_path, "iamflint"))
            FileUtils.rm_r(temp_path)
        end
        if File.exist?(old_path)
            FileUtils.mv old_path, temp_path
        end
        FileUtils.mv new_path, old_path

        # Delete old database
        if File.exist?(temp_path)
            raise "old database now at " + temp_path + " is not Xapian flint database, please delete for me" if not File.exist?(File.join(temp_path, "iamflint"))
            FileUtils.rm_r(temp_path)
        end

        # You'll want to restart your FastCGI or Mongrel processes after this,
        # so they get the new db
    end

    ######################################################################
    # Instance methods that get injected into your model.
    
    module InstanceMethods
        # Used internally
        def xapian_document_term
            self.class.to_s + "-" + self.id.to_s
        end

        # Extract value of a field from the model
        def xapian_value(field, type = nil)
            value = self[field] || self.instance_variable_get("@#{field.to_s}".to_sym) || self.send(field.to_sym)
            if type == :date
                value.utc.strftime("%Y%m%d")
            elsif type == :boolean
                value ? true : false
            else
                value.to_s
            end
        end

        # Store record in the Xapian database
        def xapian_index
            # if we have a conditional function for indexing, call it and destory object if failed
            if self.class.xapian_options.include?(:if)
                if_value = xapian_value(self.class.xapian_options[:if], :boolean)
                if not if_value
                    self.xapian_destroy
                    return
                end
            end

            # otherwise (re)write the Xapian record for the object
            doc = Xapian::Document.new
            ActsAsXapian.term_generator.document = doc

            doc.data = self.xapian_document_term

            doc.add_term("M" + self.class.to_s)
            doc.add_term("I" + doc.data)
            if self.xapian_options[:terms]
              for term in self.xapian_options[:terms]
                  doc.add_term(term[1] + xapian_value(term[0]))
              end
            end
            if self.xapian_options[:values]
              for value in self.xapian_options[:values]
                  doc.add_value(value[1], xapian_value(value[0], value[3])) 
              end
            end
            if self.xapian_options[:texts]
              for text in self.xapian_options[:texts]
                  ActsAsXapian.term_generator.increase_termpos # stop phrases spanning different text fields
                  ActsAsXapian.term_generator.index_text(xapian_value(text)) 
              end
            end

            ActsAsXapian.writable_db.replace_document("I" + doc.data, doc)
        end

        # Delete record from the Xapian database
        def xapian_destroy
            ActsAsXapian.writable_db.delete_document("I" + self.xapian_document_term)
        end

        # Used to mark changes needed by batch indexer
        def xapian_mark_needs_index
            model = self.class.to_s
            model_id = self.id
            ActiveRecord::Base.transaction do
                found = ActsAsXapianJob.delete_all([ "model = ? and model_id = ?", model, model_id])
                job = ActsAsXapianJob.new
                job.model = model
                job.model_id = model_id
                job.action = 'update'
                job.save!
            end
        end
        def xapian_mark_needs_destroy
            model = self.class.to_s
            model_id = self.id
            ActiveRecord::Base.transaction do
                found = ActsAsXapianJob.delete_all([ "model = ? and model_id = ?", model, model_id])
                job = ActsAsXapianJob.new
                job.model = model
                job.model_id = model_id
                job.action = 'destroy'
                job.save!
            end
        end
     end

    ######################################################################
    # Main entry point, add acts_as_xapian to your model.
    
    module ActsMethods
        # See top of this file for docs
        def acts_as_xapian(options)
            include InstanceMethods

            cattr_accessor :xapian_options
            self.xapian_options = options

            ActsAsXapian.init(self.class.to_s, options)

            after_save :xapian_mark_needs_index
            after_destroy :xapian_mark_needs_destroy
        end
    end
   
end

# Reopen ActiveRecord and include the acts_as_xapian method
ActiveRecord::Base.extend ActsAsXapian::ActsMethods


