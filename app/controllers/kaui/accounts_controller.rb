class Kaui::AccountsController < Kaui::EngineController

  def index
    @search_query = params[:q]

    if params[:fast] == '1' && !@search_query.blank?
      account = Kaui::Account.list_or_search(@search_query, -1, 1, options_for_klient).first
      if account.nil?
        flash[:error] = "No account matches \"#{@search_query}\""
        redirect_to kaui_engine.home_path and return
      else
        redirect_to kaui_engine.account_path(account.account_id) and return
      end
    end

    @ordering = params[:ordering] || (@search_query.blank? ? 'desc' : 'asc')
    @offset = params[:offset] || 0
    @limit = params[:limit] || 50

    @max_nb_records = @search_query.blank? ? Kaui::Account.list_or_search(nil, 0, 0, options_for_klient).pagination_max_nb_records : 0
  end

  def pagination
    searcher = lambda do |search_key, offset, limit|
      Kaui::Account.list_or_search(search_key, offset, limit, options_for_klient)
    end

    data_extractor = lambda do |account, column|
      [
          account.name,
          account.account_id,
          account.external_key,
          account.account_balance,
          account.city,
          account.country
      ][column]
    end

    formatter = lambda do |account|
      [
          view_context.link_to(account.name || '(not set)', view_context.url_for(:action => :show, :account_id => account.account_id)),
          view_context.truncate_uuid(account.account_id),
          account.external_key,
          view_context.humanized_money_with_symbol(account.balance_to_money),
          account.city,
          account.country
      ]
    end

    paginate searcher, data_extractor, formatter
  end

  def new
    @account = Kaui::Account.new
  end

  def create
    @account = Kaui::Account.new(params.require(:account).delete_if { |key, value| value.blank? })

    # Transform "1" into boolean
    @account.is_migrated = @account.is_migrated == '1'
    @account.is_notified_for_invoices = @account.is_notified_for_invoices == '1'

    begin
      @account = @account.create(current_user.kb_username, params[:reason], params[:comment], options_for_klient)
      redirect_to account_path(@account.account_id), :notice => 'Account was successfully created'
    rescue => e
      flash.now[:error] = "Error while creating account: #{as_string(e)}"
      render :action => :new
    end
  end

  def show
    # Go to the database once
    cached_options_for_klient = options_for_klient

    # Re-fetch the account with balance and CBA
    @account = Kaui::Account::find_by_id_or_key(params.require(:account_id), true, true, cached_options_for_klient)

    fetch_overdue_state = promise { @account.overdue(cached_options_for_klient) }
    fetch_account_tags = promise { @account.tags(false, 'NONE', cached_options_for_klient).sort { |tag_a, tag_b| tag_a <=> tag_b } }
    fetch_account_fields = promise { @account.custom_fields('NONE', cached_options_for_klient).sort { |cf_a, cf_b| cf_a.name.downcase <=> cf_b.name.downcase } }
    fetch_account_emails = promise { Kaui::AccountEmail.find_all_sorted_by_account_id(@account.account_id, 'NONE', cached_options_for_klient) }
    fetch_payments = promise { @account.payments(cached_options_for_klient).map! { |payment| Kaui::Payment.build_from_raw_payment(payment) } }
    fetch_payment_methods = promise(false) { Kaui::PaymentMethod.find_all_by_account_id(@account.account_id, false, cached_options_for_klient) }
    fetch_payment_methods_with_details = fetch_payment_methods.then do |pms|
      ops = []
      pms.each do |pm|
        ops << promise(false) {
          begin
            Kaui::PaymentMethod.find_by_id(pm.payment_method_id, true, cached_options_for_klient)
          rescue => e
            # Maybe the plugin is not registered or the plugin threw an exception
            Rails.logger.warn(e)
            nil
          end
        }
      end
      ops
    end
    fetch_available_tags = promise { Kaui::TagDefinition.all_for_account(cached_options_for_klient) }

    @overdue_state = wait(fetch_overdue_state)
    @tags = wait(fetch_account_tags)
    @custom_fields = wait(fetch_account_fields)
    @account_emails = wait(fetch_account_emails)
    wait(fetch_payment_methods)
    @payment_methods = wait(fetch_payment_methods_with_details).map { |pm_f| pm_f.execute }.map { |pm_f| wait(pm_f) }.reject { |pm| pm.nil? }
    @available_tags = wait(fetch_available_tags)

    @last_transaction_by_payment_method_id = {}
    wait(fetch_payments).each do |payment|
      transaction = payment.transactions.last
      transaction_date = Date.parse(transaction.effective_date)

      last_seen_transaction_date = @last_transaction_by_payment_method_id[payment.payment_method_id]
      if last_seen_transaction_date.nil? || Date.parse(last_seen_transaction_date.effective_date) < transaction_date
        @last_transaction_by_payment_method_id[payment.payment_method_id] = transaction
      end
    end

    params.permit!
  end

  def trigger_invoice
    account_id = params.require(:account_id)
    target_date = params[:target_date].presence
    dry_run = params[:dry_run] == '1'

    invoice = nil
    begin
      invoice = dry_run ? Kaui::Invoice.trigger_invoice_dry_run(account_id, target_date, false, options_for_klient) :
                          Kaui::Invoice.trigger_invoice(account_id, target_date, current_user.kb_username, params[:reason], params[:comment], options_for_klient)
    rescue KillBillClient::API::NotFound
      # Null invoice
    end

    if invoice.nil?
      redirect_to account_path(account_id), :notice => "Nothing to generate for target date #{target_date.nil? ? 'today' : target_date}"
    elsif dry_run
      @invoice = Kaui::Invoice.build_from_raw_invoice(invoice)
      @payments = []
      @payment_methods = nil
      @account = Kaui::Account.find_by_id(account_id, false, false, options_for_klient)
      render :template => 'kaui/invoices/show'
    else
      # Redirect to fetch payments, etc.
      redirect_to invoice_path(invoice.invoice_id, :account_id => account_id), :notice => "Generated invoice #{invoice.invoice_number} for target date #{invoice.target_date}"
    end
  end

  # Fetched asynchronously, as it takes time. This also helps with enforcing permissions.
  def next_invoice_date
    next_invoice = Kaui::Invoice.trigger_invoice_dry_run(params.require(:account_id), nil, true, options_for_klient)
    render :json => next_invoice ? next_invoice.target_date.to_json : nil
  end

  def edit
  end

  def update
    @account = Kaui::Account.new(params.require(:account).delete_if { |key, value| value.blank? })
    @account.account_id = params.require(:account_id)

    # Transform "1" into boolean
    @account.is_migrated = @account.is_migrated == '1'
    @account.is_notified_for_invoices = @account.is_notified_for_invoices == '1'

    @account.update(true, current_user.kb_username, params[:reason], params[:comment], options_for_klient)

    redirect_to account_path(@account.account_id), :notice => 'Account successfully updated'
  rescue => e
    flash.now[:error] = "Error while updating account: #{as_string(e)}"
    render :action => :edit
  end

  def set_default_payment_method
    account_id = params.require(:account_id)
    payment_method_id = params.require(:payment_method_id)

    Kaui::PaymentMethod.set_default(payment_method_id, account_id, current_user.kb_username, params[:reason], params[:comment], options_for_klient)

    redirect_to account_path(account_id), :notice => "Successfully set #{payment_method_id} as default"
  end

  def toggle_email_notifications
    account = Kaui::Account.new(:account_id => params.require(:account_id), :is_notified_for_invoices => params[:is_notified] == 'true')

    account.update_email_notifications(current_user.kb_username, params[:reason], params[:comment], options_for_klient)

    redirect_to account_path(account.account_id), :notice => 'Email preferences updated'
  end

  def pay_all_invoices
    payment = Kaui::InvoicePayment.new(:account_id => params.require(:account_id))

    payment.bulk_create(params[:is_external_payment] == 'true', current_user.kb_username, params[:reason], params[:comment], options_for_klient)

    redirect_to account_path(payment.account_id), :notice => 'Successfully triggered a payment for all unpaid invoices'
  end

  def validate_external_key
    external_key = params.require(:external_key)

    begin
      account = Kaui::Account::find_by_external_key(external_key, false, false, options_for_klient)
    rescue KillBillClient::API::NotFound
      account = nil
    end
    render json: {:is_found => !account.nil?}

  end
end
