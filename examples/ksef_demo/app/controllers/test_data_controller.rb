# frozen_string_literal: true

# TEST-environment data: subjects, persons and permissions (anonymous endpoints). Refused on PROD.
class TestDataController < ApplicationController
  before_action :refuse_production, except: :index

  def index; end

  def subject
    ksef_action("Create test subject") do
      body = { "subjectNip" => params[:nip].to_s.strip, "subjectType" => params[:subject_type].presence,
               "description" => params[:description].to_s, "subunits" => subunits.presence }.compact
      ksef_client.test_data.create_subject(body: body)
      { "created" => body }
    end
  end

  def remove_subject
    ksef_action("Remove test subject") do
      ksef_client.test_data.remove_subject(body: { "subjectNip" => params[:nip].to_s.strip })
      { "removed" => params[:nip] }
    end
  end

  def person
    ksef_action("Create test person") do
      body = { "nip" => params[:nip].to_s.strip, "pesel" => params[:pesel].to_s.strip,
               "isBailiff" => params[:bailiff] == "1", "description" => params[:description].to_s }
      ksef_client.test_data.create_person(body: body)
      { "created" => body }
    end
  end

  def permissions
    ksef_action("Grant test permissions") do
      body = {
        "contextIdentifier" => { "type" => "Nip", "value" => params[:context_nip].to_s.strip },
        "authorizedIdentifier" => { "type" => params[:identifier_type], "value" => params[:identifier].to_s.strip },
        "permissions" => test_permissions
      }
      ksef_client.test_data.grant_permissions(body: body)
      { "granted" => body }
    end
  end

  private

  def subunits
    params[:subunits].to_s.split(/[\s,;]+/).compact_blank.map do |nip|
      { "subjectNip" => nip, "description" => "Subunit #{nip} of #{params[:nip]}" }
    end
  end

  def test_permissions
    (Array(params[:permissions]) & TokensController::PERMISSIONS).map do |permission|
      { "permissionType" => permission, "description" => params[:description].presence || permission }
    end
  end

  def refuse_production
    redirect_to test_data_path, alert: "Test data endpoints do not exist on PROD." unless test_environment?
  end
end
