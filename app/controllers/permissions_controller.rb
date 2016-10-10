class PermissionsController < ApplicationController

  def index
    provider_id = @current_user.provider_id
    response = cmr_client.get_permissions_for_provider(provider_id, token)

    if params[:new_acl] && response.success?
      # indexing of new acls makes it such that the first request does not always return the newly created ACL
      # if the new acl is not in the response, we are making the request again until the request fails
      # or we get the new ACL
      has_new_acl = false
      until has_new_acl
        resp_concept_ids = []
        response.body['items'].each do |item|
          if item['concept_id'] == params[:new_acl]
            has_new_acl = true
            break
          end
        end
        response = cmr_client.get_permissions_for_provider(provider_id, token)
        break if response.error?
      end
    end

    unless response.success?
      Rails.logger.error("Error getting permissions: #{response.inspect}")
      error = Array.wrap(response.body['errors'])[0]
      flash[:error] = error
    end

    # puts response.body.inspect
    @permissions = response.body['items']

    # This block searches through the permissions of each group and creates a summary for display
    @permissions.each do |perm|
      permission_summary = {}
      permission_summary_list = []
      group_permissions = perm['acl']['group_permissions']
      group_permissions.each do |group_perm|
        perm_list = group_perm['permissions']
        perm_list.each do |type|
          permission_summary[type] = type
        end
      end

      permission_summary.keys.each do |key|
        key = 'search' if key == 'read'

        permission_summary_list << key.capitalize
      end

      perm['permission_summary'] = permission_summary_list.join ' & '
    end
  end

  def new
    @collection_ids = []
    @granules_options = []
    @collections_options = []
    @permission_name = params[:permission_name]
    @groups = get_groups(params[:filters])
  end

  def show
    # stub
  end

  def create
    hasError = false
    msg = ''
    if params[:permission_name].blank?
      hasError = true
      msg = 'Permission Name is required.'
    elsif params[:collections].blank? || params[:collections] == 'select'
      hasError = true
      msg = 'Collections must be specified.'
    elsif params[:granules].blank? || params[:granules] == 'select'
      hasError = true
      msg = 'Granules must be specified.'
    elsif params[:search_groups].nil? && params[:search_and_order_groups].nil?
      hasError = true
      msg = 'Please specify at least one Search group or one Search & Order group.'
    end

    if hasError == true
      Rails.logger.error("Permission Creation Error: #{msg}")
      flash[:error] = msg
      @collections = params[:collections]
      @granules = params[:granules]
      @permission_name = params[:permission_name]
      @groups = get_groups(params[:filters])
      render :new
      return
    end

    # Global provider ID for the current user, based their current provider
    # to use a different provider_id, user will need to change current provider
    provider_id = @current_user.provider_id

    collections = params[:collections]
    granules = params[:granules]

    request_object = construct_request_object(params[:permission_name],
      provider_id,
      params[:collections],
      params[:granules],
      params[:search_groups],
      params[:search_and_order_groups])

    response = cmr_client.add_group_permissions(request_object, token)

    if response.success?
      flash[:success] = 'Permission was successfully created.'
      Rails.logger.info("#{@current_user.urs_uid} CREATED catalog item ACL for #{provider_id}. #{response.body}")

      # passing in concept_id to redirect, because indexing is not happening fast enough
      concept_id = response.body['concept_id']
      redirect_to permissions_path(new_acl: concept_id)
    else
      Rails.logger.error("Permission Creation Error: #{response.inspect}")
      permission_creation_error = Array.wrap(response.body['errors'])[0]
      flash[:error] = permission_creation_error
      @collections = params[:collections]
      @granules = params[:granules]
      @permission_name = params[:permission_name]
      @groups = get_groups(params[:filters])
      render :new
    end
  end

  private

  def get_groups(filters)
    if filters && filters['member']
      filters['options'] = { 'member' => { 'and' => true } }
    end

    groups_response = cmr_client.get_cmr_groups(filters, token)
    groups = []

    #TODO!  How do we get all groups for a given provider?

    if groups_response.success?
      tmp_groups = groups_response.body['items']
      tmp_groups.each do |group|
        opt = [group['name'], group['concept_id']]
        groups << opt
      end
    else
      Rails.logger.error("Get Cmr Groups Error: #{groups_response.inspect}")
      flash[:error] = Array.wrap(groups_response.body['errors'])[0]
      groups = nil
    end
    return groups
  end

  def construct_request_object(permission_name, provider_id, collections, granules, search_groups, search_and_order_groups)
    req_obj = {
      'group_permissions' => Array.new,
      'catalog_item_identity' => {
        'name' => params[:permission_name],
        'provider_id' => provider_id,
        'granule_applicable' => true
      }
    }

    # TODO -- we will add another condition here to add
    # specifc collection IDs
    collection_applicable = false
    if collections == 'all-collections'
      collection_applicable = true
    end

    req_obj['catalog_item_identity']['collection_applicable'] = collection_applicable

    granule_applicable = false
    if granules == 'all-granules'
        granule_applicable = true
    end

    req_obj['catalog_item_identity']['granule_applicable'] = granule_applicable
    req_obj['group_permissions'] = Array.new

    if ! search_groups.nil?
      search_groups.each do |group|
        search_permission = {
          'group_id'=> group,
          'permissions'=> ['read'] # aka "search"
        }
        req_obj['group_permissions'] << search_permission
        end
    end


    if ! search_and_order_groups.nil?
      search_and_order_groups.each do |group|
        search_and_order_permission = {
            'group_id'=> group,
            'permissions'=> ['read', 'order'] # aka "search"
        }
        req_obj['group_permissions'] << search_and_order_permission
      end
    end
    return req_obj
  end
end