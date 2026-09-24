# frozen_string_literal: true

# Renders a `SchemaForm` as nested form controls, prefilled from an invoice XML. Inputs carry no
# names: the browser serializes the DOM back to XML (`data-x` = element, `data-xval` = its text,
# `data-xattr` = attribute), and an empty element is simply left out.
module SchemaFormHelper
  ENUM_SELECT_LIMIT = 30

  # @param model [SchemaForm]
  # @param xml [String, nil] invoice to prefill from
  def schema_form(model, xml)
    @schema_datalists = {}
    doc = Nokogiri::XML(xml.to_s).tap(&:remove_namespaces!)
    form = schema_element(model.root, [doc.root].compact, 0)
    form + safe_join(@schema_datalists.map { |id, enum| schema_datalist(id, enum) })
  end

  private

  def schema_element(element, nodes, depth)
    element.repeated? ? schema_list(element, nodes, depth) : schema_node(element, nodes.first, depth)
  end

  # A repeated element: the present items, a <template> for new ones and an "add" button.
  def schema_list(element, nodes, depth)
    items = Array.new([nodes.size, element.min].max) { |i| schema_node(element, nodes[i], depth, removable: true) }
    tag.div(class: "space-y-2 rounded-lg border border-dashed border-slate-300 p-2", data: { xlist: element.name }) do
      safe_join([
                  tag.div(safe_join(items), data: { xitems: true }, class: "space-y-2"),
                  tag.template(schema_node(element, nil, depth, removable: true)),
                  tag.button("+ #{element.name} #{schema_cardinality(element)}", type: "button", data: { xadd: true },
                                                                                 class: "btn-secondary py-1! text-xs!")
                ])
    end
  end

  def schema_node(element, node, depth, removable: false)
    return schema_leaf(element, node, removable) if element.leaf?

    tag.details(open: depth < 1 || (node && depth < 3), data: { x: element.name },
                class: "group/x rounded-lg bg-white ring-1 ring-slate-200 open:ring-slate-300") do
      tag.summary(class: "flex cursor-pointer items-start gap-2 px-3 py-2 select-none") do
        safe_join([schema_label(element), (schema_remove_button if removable)].compact)
      end +
        tag.div(class: "space-y-2 border-t border-slate-100 p-3 pl-4") do
          safe_join([schema_attributes(element), schema_group(element.group, node, depth + 1)])
        end
    end
  end

  def schema_leaf(element, node, removable)
    tag.div(data: { x: element.name }, class: "grid items-start gap-2 sm:grid-cols-5") do
      safe_join([
                  tag.div(schema_label(element), class: "sm:col-span-2"),
                  tag.div(class: "flex gap-1 sm:col-span-3") do
                    safe_join([schema_attributes(element), schema_input(element, node&.text),
                               (schema_remove_button if removable)].compact)
                  end
                ])
    end
  end

  def schema_group(group, node, depth)
    return "".html_safe if group.nil?
    return schema_choice(group, node, depth) if group.kind == :choice

    safe_join(group.items.map { |item| schema_item(item, node, depth) })
  end

  def schema_item(item, node, depth)
    return schema_group(item, node, depth) if item.is_a?(SchemaForm::Group)

    schema_element(item, node ? node.element_children.select { |c| c.name == item.name } : [], depth)
  end

  # One branch is active: the one whose elements the XML contains, else the first (or none when the
  # choice is optional). Inactive branches stay in the DOM, marked so the serializer skips them.
  def schema_choice(group, node, depth)
    present = node ? node.element_children.map(&:name) : []
    active = group.items.index { |item| schema_names(item).intersect?(present) } || (group.min.zero? ? -1 : 0)
    options = group.items.each_with_index.map { |item, i| [schema_names(item).first(3).join(" + "), i] }
    options.unshift(["— none —", -1]) if group.min.zero?
    tag.div(data: { xchoice: true }, class: "space-y-2 rounded-lg bg-amber-50/60 p-2 ring-1 ring-amber-200") do
      select = tag.select(options_for_select(options, active), data: { xchoice_select: true },
                                                               class: "input w-auto! py-1! text-xs!")
      branches = group.items.each_with_index.map do |item, i|
        tag.div(schema_item(item, node, depth), data: { xbranch: i, inactive: (i != active) || nil },
                                                hidden: i != active, class: "space-y-2")
      end
      tag.div(safe_join(["One of:", select], " "), class: "text-xs font-medium text-amber-800") + safe_join(branches)
    end
  end

  def schema_names(item)
    item.is_a?(SchemaForm::Group) ? item.items.flat_map { |i| schema_names(i) } : [item.name]
  end

  def schema_input(element, value)
    type = element.simple_type
    css = "input py-1! text-sm"
    if type.enum.size.between?(1, ENUM_SELECT_LIMIT)
      options = type.enum.map { |v, doc| [doc.empty? ? v : "#{v} — #{doc.truncate(70)}", v] }
      return tag.select(options_for_select([["", ""], *options], value), data: { xval: true }, class: css)
    end

    attrs = { value: value, data: { xval: true }, class: "#{css} font-mono", maxlength: type.max_length }
    attrs[:list] = schema_datalist_id(type) if type.enum.size > ENUM_SELECT_LIMIT
    case type.base
    when :date then tag.input(**attrs, type: "date", class: css)
    when :decimal, :integer then tag.input(**attrs, inputmode: "decimal")
    else type.max_length.to_i > 256 ? tag.textarea(value, **attrs.except(:value), rows: 2) : tag.input(**attrs)
    end
  end

  def schema_attributes(element)
    safe_join(element.attributes.map do |attr|
      tag.input(type: "hidden", value: attr.fixed, data: { xattr: attr.name })
    end)
  end

  def schema_label(element)
    tag.div(class: "min-w-0 flex-1") do
      tag.div(class: "flex flex-wrap items-center gap-1.5") do
        tag.span(element.name, class: "font-mono text-xs font-semibold text-slate-900") +
          tag.span(schema_cardinality(element), class: "rounded bg-slate-100 px-1 text-[10px] text-slate-500")
      end + schema_doc(element)
    end
  end

  def schema_doc(element)
    return "".html_safe if element.doc.empty?

    tag.p(element.doc, title: element.doc, class: "line-clamp-2 text-[11px] leading-snug text-slate-500")
  end

  def schema_cardinality(element)
    max = element.max >= SchemaForm::UNBOUNDED ? "∞" : element.max
    if element.min == element.max
      return "required in its group" if element.conditional

      element.min == 1 ? "required" : element.min.to_s
    else
      "#{element.min}..#{max}"
    end
  end

  def schema_remove_button
    tag.button(icon(:x, "size-4"), type: "button", title: "Remove", data: { xremove: true },
                                   class: "rounded-md p-1 text-slate-400 hover:bg-rose-50 hover:text-rose-600")
  end

  def schema_datalist_id(type)
    "dl-#{type.name}".tap { |id| @schema_datalists[id] ||= type.enum }
  end

  def schema_datalist(id, enum)
    tag.datalist(id: id) { safe_join(enum.map { |value, doc| tag.option(value: value, label: doc) }) }
  end
end
