class Api::V1::Accounts::ContactsController < Api::V1::Accounts::BaseController
  include Sift
  sort_on :email, type: :string
  sort_on :name, internal_name: :order_on_name, type: :scope, scope_params: [:direction]
  sort_on :phone_number, type: :string
  sort_on :last_activity_at, internal_name: :order_on_last_activity_at, type: :scope, scope_params: [:direction]
  sort_on :company, internal_name: :order_on_company_name, type: :scope, scope_params: [:direction]
  sort_on :city, internal_name: :order_on_city, type: :scope, scope_params: [:direction]
  sort_on :country, internal_name: :order_on_country_name, type: :scope, scope_params: [:direction]

  RESULTS_PER_PAGE = 15

  before_action :check_authorization
  before_action :set_current_page, only: [:index, :active, :search, :filter]
  before_action :fetch_contact, only: [:show, :update, :destroy, :avatar, :contactable_inboxes, :destroy_custom_attributes]
  before_action :set_include_contact_inboxes, only: [:index, :search, :filter]

  def index
    @contacts_count = resolved_contacts.count
    @contacts = fetch_contacts_with_conversation_count(resolved_contacts)
  end

  def search
    render json: { error: 'Specify search string with parameter q' }, status: :unprocessable_entity if params[:q].blank? && return

    contacts = resolved_contacts.where(
      'name ILIKE :search OR email ILIKE :search OR phone_number ILIKE :search OR contacts.identifier LIKE :search',
      search: "%#{params[:q]}%"
    )
    @contacts_count = contacts.count
    @contacts = fetch_contacts_with_conversation_count(contacts)
  end

  def import
    render json: { error: I18n.t('errors.contacts.import.failed') }, status: :unprocessable_entity and return if params[:import_file].blank?

    ActiveRecord::Base.transaction do
      import = Current.account.data_imports.create!(data_type: 'contacts')
      import.import_file.attach(params[:import_file])
    end

    head :ok
  end

  # returns online contacts
  def active
    contacts = Current.account.contacts.where(id: ::OnlineStatusTracker
                  .get_available_contact_ids(Current.account.id))
    @contacts_count = contacts.count
    @contacts = contacts.page(@current_page)
  end

  def show; end

  def filter
    result = ::Contacts::FilterService.new(params.permit!, current_user).perform
    contacts = result[:contacts]
    @contacts_count = result[:count]
    @contacts = fetch_contacts_with_conversation_count(contacts)
  end

  def contactable_inboxes
    @all_contactable_inboxes = Contacts::ContactableInboxesService.new(contact: @contact).get
    @contactable_inboxes = @all_contactable_inboxes.select { |contactable_inbox| policy(contactable_inbox[:inbox]).show? }
  end

  # TODO : refactor this method into dedicated contacts/custom_attributes controller class and routes
  def destroy_custom_attributes
    @contact.custom_attributes = @contact.custom_attributes.excluding(params[:custom_attributes])
    @contact.save!
  end

  def create
    ActiveRecord::Base.transaction do
      @contact = Current.account.contacts.new(permitted_params.except(:avatar_url))
      @contact.save!
      @contact_inbox = build_contact_inbox
      process_avatar
    end
  end

  def update
    @contact.assign_attributes(contact_update_params)
    @contact.save!
    process_avatar if permitted_params[:avatar].present? || permitted_params[:avatar_url].present?
  end

  def destroy
    if ::OnlineStatusTracker.get_presence(
      @contact.account.id, 'Contact', @contact.id
    )
      return render_error({ message: I18n.t('contacts.online.delete', contact_name: @contact.name.capitalize) },
                          :unprocessable_entity)
    end

    @contact.destroy!
    head :ok
  end

  def avatar
    @contact.avatar.purge if @contact.avatar.attached?
    @contact
  end

  private

  # TODO: Move this to a finder class
  def resolved_contacts
    return @resolved_contacts if @resolved_contacts

    @resolved_contacts = Current.account.contacts.resolved_contacts

    @resolved_contacts = @resolved_contacts.tagged_with(params[:labels], any: true) if params[:labels].present?
    @resolved_contacts
  end

  def set_current_page
    @current_page = params[:page] || 1
  end

  def fetch_contacts_with_conversation_count(contacts)
    contacts_with_conversation_count = filtrate(contacts).left_outer_joins(:conversations)
                                                         .select('contacts.*, COUNT(conversations.id) as conversations_count')
                                                         .group('contacts.id')
                                                         .includes([{ avatar_attachment: [:blob] }])
                                                         .page(@current_page).per(RESULTS_PER_PAGE)

    return contacts_with_conversation_count.includes([{ contact_inboxes: [:inbox] }]) if @include_contact_inboxes

    contacts_with_conversation_count
  end

  def build_contact_inbox
    return if params[:inbox_id].blank?

    inbox = Current.account.inboxes.find(params[:inbox_id])
    source_id = params[:source_id] || SecureRandom.uuid
    ContactInbox.create(contact: @contact, inbox: inbox, source_id: source_id)
  end

  def permitted_params
    params.permit(:name, :identifier, :email, :phone_number, :avatar, :avatar_url, additional_attributes: {}, custom_attributes: {})
  end

  def contact_custom_attributes
    return @contact.custom_attributes.merge(permitted_params[:custom_attributes]) if permitted_params[:custom_attributes]

    @contact.custom_attributes
  end

  def contact_update_params
    # we want the merged custom attributes not the original one
    permitted_params.except(:custom_attributes, :avatar_url).merge({ custom_attributes: contact_custom_attributes })
  end

  def set_include_contact_inboxes
    @include_contact_inboxes = if params[:include_contact_inboxes].present?
                                 params[:include_contact_inboxes] == 'true'
                               else
                                 true
                               end
  end

  def fetch_contact
    @contact = Current.account.contacts.includes(contact_inboxes: [:inbox]).find(params[:id])
  end

  def process_avatar
    ::Avatar::AvatarFromUrlJob.perform_later(@contact, params[:avatar_url]) if params[:avatar_url].present?
  end

  def render_error(error, error_status)
    render json: error, status: error_status
  end
end
