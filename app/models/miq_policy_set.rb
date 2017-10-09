class MiqPolicySet < ApplicationRecord
  acts_as_miq_set

  before_validation :default_name_to_guid, :on => :create
  before_destroy    :destroy_policy_tags

  attr_accessor :reserved

  def notes
    set_data.kind_of?(Hash) && set_data.key?(:notes) ? set_data[:notes] : nil
  end

  def notes=(data)
    return if data.nil?
    self.set_data ||= {}
    self.set_data[:notes] = data[0..511]
  end

  def active?
    !members.all? { |p| !p.active }
  end

  def destroy_policy_tags
    # handle policy assignment removal for deleted policy profile
    Tag.find_by(:name => "/miq_policy/assignment/#{self.class.to_s.underscore}/#{id}").try!(:destroy)
  end

  def add_policy(policy)
    add_member(policy)
  end

  def remove_policy(policy)
    remove_member(policy)
  end

  def get_policies
    miq_policies
  end

  def add_to(ids, db)
    operation_on_multiple(ids, db, :add_policy)
  end

  def remove_from(ids, db)
    operation_on_multiple(ids, db, :remove_policy)
  end

  private def operation_on_multiple(ids, db, operation)
    model = db.respond_to?(:constantize) ? db.constantize : db
    model.where(:id => ids).each do |rec|
      rec.send(operation, self)
    end
  end

  def export_to_array
    [self.class.to_s => ContentExporter.export_to_hash(attributes, "MiqPolicy", members)]
  end

  def export_to_yaml
    export_to_array.to_yaml
  end

  def self.import_from_hash(policy_profile, options = {})
    status = {:class => name, :description => policy_profile["description"], :children => []}
    pp = policy_profile.delete("MiqPolicy") do |_k|
      raise _("No Policies for Policy Profile == %{profile}") % {:profile => policy_profile.inspect}
    end

    policies = []
    pp.each do |p|
      policy, s = MiqPolicy.import_from_hash(p, options)
      status[:children].push(s)
      policies.push(policy)
    end

    pset = MiqPolicySet.find_by(:guid => policy_profile["guid"])
    msg_pfx = "Importing Policy Profile: guid=[#{policy_profile["guid"]}] description=[#{policy_profile["description"]}]"
    if pset.nil?
      pset = MiqPolicySet.new(policy_profile)
      status[:status] = :add
    else
      status[:old_description] = pset.description
      pset.attributes = policy_profile
      status[:status] = :update
    end

    unless pset.valid?
      status[:status]   = :conflict
      status[:messages] = pset.errors.full_messages
    end

    pset["mode"] ||= "control" # Default "mode" value to true to support older export decks that don't have a value set.

    msg = "#{msg_pfx}, Status: #{status[:status]}"
    msg += ", Messages: #{status[:messages].join(",")}" if status[:messages]
    if options[:preview] == true
      MiqPolicy.logger.info("[PREVIEW] #{msg}")
    else
      MiqPolicy.logger.info(msg)
      pset.save!
      policies.each { |p| pset.add_member(p) }
    end

    return pset, status
  end

  def self.import_from_yaml(fd)
    input = YAML.load(fd)
    input.collect do |e|
      _p, stat = import_from_hash(e["MiqPolicySet"])
      stat
    end
  end

  def self.seed
    fixture_file = File.join(FIXTURE_DIR, "miq_policy_sets.yml")
    fixtures = File.exist?(fixture_file) ? YAML.load_file(fixture_file) : []
    MiqPolicy.import_from_array(fixtures, :save => true)

    all.each do |ps|
      if ps.mode.nil?
        _log.info("Updating [#{ps.name}]")
        ps.update_attribute(:mode, "control")
      end
    end
  end
end # class MiqPolicySet
