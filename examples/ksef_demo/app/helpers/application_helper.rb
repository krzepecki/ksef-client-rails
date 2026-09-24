# frozen_string_literal: true

# View helpers: navigation, badges and a generic renderer that turns API responses (hashes,
# arrays of records, XML) into readable tables instead of raw JSON dumps.
module ApplicationHelper
  NAVIGATION = [
    [nil, [["Overview", :root_path, :grid], ["Authentication", :auth_path, :key]]],
    ["Invoices", [["Issue invoice", :new_invoice_path, :document], ["Browse invoices", :invoices_path, :list],
                  ["QR codes", :qr_path, :qr]]],
    ["Sessions", [["Sessions & UPO", :sessions_path, :stack], ["Batch session", :batch_path, :layers],
                  ["Export & sync", :exports_path, :download]]],
    ["Access", [["KSeF tokens", :tokens_path, :token], ["Certificates", :certificates_path, :badge],
                ["Permissions", :permissions_path, :shield], ["Limits", :limits_path, :gauge]]],
    ["TEST environment", [["Test data", :test_data_path, :flask]]]
  ].freeze

  # Simple 24×24 stroke icons.
  ICONS = {
    grid: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z",
    key: "M14 10a4 4 0 1 0-4 4M11.5 12.5 20 21M17 18l2-2M15 16l2-2",
    document: "M7 3h7l5 5v13H7zM14 3v5h5M10 13h6M10 17h6",
    list: "M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01",
    qr: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h2v2h-2zM18 18h2v2h-2zM14 18h2M18 14h2",
    stack: "M4 7h16M4 12h16M4 17h16M4 4h16v16H4z",
    layers: "M12 3 3 8l9 5 9-5zM3 13l9 5 9-5M3 17l9 5 9-5",
    download: "M12 3v12M7 10l5 5 5-5M4 19h16",
    token: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 8v8M8 12h8",
    badge: "M12 3a6 6 0 1 0 0 12 6 6 0 0 0 0-12zM9 14l-2 7 5-3 5 3-2-7",
    shield: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z",
    gauge: "M4 17a8 8 0 1 1 16 0M12 17l4-6",
    flask: "M9 3h6M10 3v6l-5 9a2 2 0 0 0 2 3h10a2 2 0 0 0 2-3l-5-9V3",
    check: "M5 12l5 5L20 7",
    x: "M6 6l12 12M18 6 6 18",
    copy: "M9 9h11v11H9zM5 15V4h11"
  }.freeze

  def icon(name, css = "size-5")
    tag.svg(class: css, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": 1.6,
            "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": true) do
      tag.path(d: ICONS.fetch(name))
    end
  end

  def nav_link(label, path_helper, icon_name)
    path = public_send(path_helper)
    active = path == active_nav_path
    css = active ? "bg-slate-800 text-white" : "text-slate-400 hover:bg-slate-800/60 hover:text-white"
    link_to path, class: "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium #{css}" do
      safe_join([icon(icon_name, "size-5 shrink-0"), label])
    end
  end

  # The longest navigation path the current URL starts with (/invoices/new beats /invoices).
  def active_nav_path
    @active_nav_path ||= @active_nav ||
                         NAVIGATION.flat_map { |_, items| items.map { |item| public_send(item[1]) } }
                                   .select { |p| request.path == p || (p != "/" && request.path.start_with?("#{p}/")) }
                                   .max_by(&:length)
  end

  def environment_badge(env = settings["environment"])
    css = { "test" => "bg-emerald-100 text-emerald-800 ring-emerald-600/20",
            "demo" => "bg-amber-100 text-amber-800 ring-amber-600/20" }
          .fetch(env, "bg-rose-100 text-rose-800 ring-rose-600/20")
    tag.span(env.upcase, class: "rounded-md px-2 py-0.5 text-xs font-semibold ring-1 ring-inset #{css}")
  end

  # Colour-coded KSeF status code: 200 ok, 1xx in progress, everything else an error.
  def status_badge(code, description = nil)
    css = case code.to_i
          when 200..299 then "bg-emerald-50 text-emerald-700 ring-emerald-600/20"
          when 100..199 then "bg-sky-50 text-sky-700 ring-sky-600/20"
          else "bg-rose-50 text-rose-700 ring-rose-600/20"
          end
    tag.span(class: "inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-medium ring-1 " \
                    "ring-inset #{css}") do
      safe_join([tag.span(code, class: "font-mono font-semibold"), description].compact, " ")
    end
  end

  def pill(text, tone = :slate)
    css = { slate: "bg-slate-100 text-slate-700", green: "bg-emerald-100 text-emerald-800",
            red: "bg-rose-100 text-rose-800", blue: "bg-sky-100 text-sky-800",
            amber: "bg-amber-100 text-amber-800" }.fetch(tone)
    tag.span(text, class: "inline-flex rounded-full px-2 py-0.5 text-xs font-medium #{css}")
  end

  def copy_button(text, label: nil)
    tag.button(type: "button", "data-copy": text, title: "Copy",
               class: "inline-flex items-center gap-1 rounded-md px-1.5 py-1 text-xs text-slate-500 " \
                      "hover:bg-slate-100 hover:text-slate-800") do
      safe_join([icon(:copy, "size-3.5"), label].compact)
    end
  end

  def code_block(text, max_height: "max-h-96")
    tag.div(class: "group relative") do
      tag.div(copy_button(text, label: "Copy"), class: "absolute right-2 top-2 rounded-md bg-white/90") +
        tag.pre(text, class: "#{max_height} overflow-auto rounded-lg bg-slate-950 p-4 font-mono text-xs " \
                             "leading-relaxed text-slate-200 whitespace-pre-wrap break-all")
    end
  end

  # Renders any API value: hashes as key/value lists, arrays of hashes as tables, XML/long text as
  # code blocks, `{code, description}` as a status badge.
  def render_value(value, depth = 0)
    case value
    when Hash then status_hash?(value) ? status_with_details(value) : key_value_list(value, depth)
    when Array then render_array(value, depth)
    when true, false then pill(value.to_s, value ? :green : :slate)
    when nil then tag.span("—", class: "text-slate-400")
    when String then render_string(value)
    else tag.span(value.to_s, class: "font-mono text-sm")
    end
  end

  def key_value_list(hash, depth)
    return tag.span("{}", class: "text-slate-400") if hash.empty?

    tag.dl(class: "divide-y divide-slate-100 #{'rounded-lg ring-1 ring-slate-200' if depth.positive?}") do
      safe_join(hash.map do |key, val|
        tag.div(class: "grid gap-1 px-3 py-2 sm:grid-cols-4 sm:gap-4") do
          tag.dt(label_for(key), class: "text-xs font-medium text-slate-500 sm:pt-0.5") +
            tag.dd(render_value(val, depth + 1), class: "min-w-0 text-sm text-slate-900 sm:col-span-3")
        end
      end)
    end
  end

  # API keys (camelCase) become words; labels written by the demo ("KSeF number") stay as they are.
  def label_for(key)
    key = key.to_s
    key.include?(" ") ? key : key.underscore.humanize(capitalize: false)
  end

  def render_array(array, depth)
    return tag.span("empty list", class: "text-sm text-slate-400") if array.empty?
    return records_table(array) if array.all?(Hash)

    tag.ul(class: "space-y-1") { safe_join(array.map { |item| tag.li(render_value(item, depth + 1)) }) }
  end

  def records_table(records)
    columns = records.flat_map(&:keys).uniq.first(9)
    tag.div(class: "overflow-x-auto rounded-lg ring-1 ring-slate-200") do
      tag.table(class: "min-w-full divide-y divide-slate-200 text-sm") do
        tag.thead(class: "bg-slate-50") do
          tag.tr do
            safe_join(columns.map do |c|
                        tag.th(c.to_s,
                               class: "px-3 py-2 text-left text-xs font-semibold text-slate-600 whitespace-nowrap")
                      end)
          end
        end +
          tag.tbody(class: "divide-y divide-slate-100 bg-white") do
            safe_join(records.map do |row|
              tag.tr { safe_join(columns.map { |c| tag.td(compact_value(row[c]), class: "px-3 py-2 align-top") }) }
            end)
          end
      end
    end
  end

  # One-line form of a nested value for table cells.
  def compact_value(value)
    case value
    when Hash
      return status_with_details(value) if status_hash?(value)

      tag.span(value.map { |k, v| "#{k}: #{v.is_a?(Hash) ? v.values.join(' ') : v}" }.join(", "),
               class: "text-xs text-slate-600")
    when Array then tag.span(value.map { |v| v.is_a?(Hash) ? v.values.join(" ") : v }.join(", "), class: "text-xs")
    when nil then tag.span("—", class: "text-slate-400")
    when true, false then pill(value.to_s, value ? :green : :slate)
    else tag.span(value.to_s, class: "whitespace-nowrap font-mono text-xs")
    end
  end

  def render_string(text)
    return code_block(text) if text.start_with?("<?xml", "<") || text.include?("\n") || text.length > 160
    if text.length > 40
      return tag.span(safe_join([text, copy_button(text)]),
                      class: "inline-flex items-center gap-1 break-all font-mono text-xs")
    end

    tag.span(text, class: "break-words")
  end

  def status_hash?(value)
    value.key?("code") && value.key?("description") && value.size <= 4
  end

  def status_with_details(value)
    details = Array(value["details"])
    return status_badge(value["code"], value["description"]) if details.empty?

    tag.div(class: "space-y-1") do
      status_badge(value["code"], value["description"]) +
        tag.ul(class: "list-disc pl-5 text-xs text-rose-700") { safe_join(details.map { |d| tag.li(d.to_s) }) }
    end
  end

  def format_time(value)
    time = value.is_a?(String) ? Time.zone.parse(value) : value
    time&.in_time_zone("Europe/Warsaw")&.strftime("%Y-%m-%d %H:%M:%S")
  rescue ArgumentError
    value
  end

  def money(value, currency = "PLN")
    "#{format('%.2f', value).gsub(/\B(?=(\d{3})+(?!\d))/, ' ')} #{currency}"
  end

  # An amount of a draft whose numbers the builder may refuse (the form shows that error) — "—" then.
  def draft_money
    money(yield)
  rescue Ksef::ConfigurationError
    "—"
  end

  private

  # Every non-GET form (`form_with`, `button_to`) gets its CSRF token here — and next to it the environment
  # and NIP the page shows, which `ApplicationController#verify_page_context` checks.
  def token_tag(...)
    safe_join([super, hidden_field_tag(:page_context, page_context, id: nil, autocomplete: "off")])
  end
end
