class Project < ActiveRecord::Base
  include Searchable
  include SourceRank

  validates_presence_of :name, :platform

  #  validate unique name and platform (case?)

  has_many :versions
  has_many :dependencies, -> { group 'project_name' }, through: :versions
  has_many :github_contributions, through: :github_repository
  has_many :dependents, class_name: 'Dependency'
  belongs_to :github_repository

  scope :platform, ->(platform) { where('lower(platform) = ?', platform.downcase) }
  scope :with_homepage, -> { where("homepage <> ''") }
  scope :with_repository_url, -> { where("repository_url <> ''") }
  scope :without_repository_url, -> { where("repository_url IS ? OR repository_url = ''", nil) }
  scope :with_repo, -> { includes(:github_repository).where('github_repositories.id IS NOT NULL') }
  scope :without_repo, -> { where(github_repository_id: nil) }

  scope :with_github_url, -> { where('repository_url ILIKE ?', '%github.com%') }
  scope :with_gitlab_url, -> { where('repository_url ILIKE ?', '%gitlab.com%') }
  scope :with_bitbucket_url, -> { where('repository_url ILIKE ?', '%bitbucket.org%') }
  scope :with_launchpad_url, -> { where('repository_url ILIKE ?', '%launchpad.net%') }
  scope :with_sourceforge_url, -> { where('repository_url ILIKE ?', '%sourceforge.net%') }

  before_save :normalize_licenses
  after_create :update_github_repo

  def to_param
    { name: name, platform: platform.downcase }
  end

  def to_s
    name
  end

  def latest_version
    @latest_version ||= versions.to_a.sort.first
  end

  def owner
    return nil unless github_repository
    GithubUser.find_by_login github_repository.owner_name
  end

  def platform_class
    "Repositories::#{platform}".constantize
  end

  def color
    Languages::Language[language].try(:color) || platform_class.color
  end

  def mlt
    begin
      results = Project.__elasticsearch__.client.mlt(id: self.id, index: 'projects', type: 'project', mlt_fields: 'keywords,platform,description,repository_url', min_term_freq: 1, min_doc_freq: 2)
      ids = results['hits']['hits'].map{|h| h['_id']}
      Project.where(id: ids).limit(5).includes(:versions, :github_repository)
    rescue
      []
    end
  end

  def stars
    github_repository.try(:stargazers_count) || 0
  end

  def language
    github_repository.try(:language)
  end

  def repo_name
    github_repository.try(:full_name)
  end

  def description
    if platform == 'Go'
      github_repository.try(:description).presence || read_attribute(:description)
    else
      read_attribute(:description).presence || github_repository.try(:description)
    end
  end

  def homepage
    read_attribute(:homepage).presence || github_repository.try(:homepage)
  end

  def dependent_projects(limit = nil)
    deps = dependents.includes(:version => :project).map(&:version).map(&:project).uniq.sort_by(&:name)
    limit ? deps.first(limit) : deps
  end

  def self.undownloaded_repos
    with_github_url.without_repo
  end

  def self.license(license)
    where('? = ANY("normalized_licenses")', license)
  end

  def self.language(language)
    joins(:github_repository).where('github_repositories.language ILIKE ?', language)
  end

  def self.popular_languages(options = {})
    search('*', options).response.facets[:languages][:terms]
  end

  def self.popular_platforms(options = {})
    search('*', options).response.facets[:platforms][:terms]
  end

  def self.popular_licenses(options = {})
    search('*', options).response.facets[:licenses][:terms].reject{ |t| t.term == 'Other' }
  end

  def self.popular(options = {})
    search('*', options.merge(sort: 'rank', order: 'desc')).records.includes(:versions, :github_repository).reject{|p| p.github_repository.nil? }
  end

  def normalize_licenses
    if licenses.blank?
      normalized = []
    elsif licenses.length > 150
      normalized = ['Other']
    else
      normalized = licenses.split(',').map do |license|
        Spdx.find(license).try(:id)
      end.compact
      normalized = ['Other'] if normalized.empty?
    end
    self.normalized_licenses = normalized
  end

  def update_github_repo
    name_with_owner = github_name_with_owner
    if name_with_owner
      puts name_with_owner
    else
      puts repository_url
      return false
    end

    begin
      r = AuthToken.client.repo(name_with_owner).to_hash
      return false if r.nil? || r.empty?
      g = GithubRepository.find_or_initialize_by(r.slice(:full_name))
      g.owner_id = r[:owner][:id]
      g.assign_attributes r.slice(*GithubRepository::API_FIELDS)
      g.save
      self.github_repository_id = g.id
      self.save
    rescue Octokit::NotFound, Octokit::Forbidden => e
      begin
        response = Net::HTTP.get_response(URI(github_url))
        if response.code.to_i == 301
          self.repository_url = URI(response['location']).to_s
          update_github_repo
        end
      rescue URI::InvalidURIError => e
        p e
      end
    end
  end

  def github_url
    return nil if repository_url.blank? || github_name_with_owner.blank?
    "https://github.com/#{github_name_with_owner}"
  end

  def github_name_with_owner
    GithubRepository.extract_full_name(repository_url)
  end
end
