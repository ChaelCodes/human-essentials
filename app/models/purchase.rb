# == Schema Information
#
# Table name: purchases
#
#  id                             :bigint           not null, primary key
#  adult_incontinence_money_cents :integer          default(0), not null
#  amount_spent_in_cents          :integer
#  comment                        :text
#  diapers_money_cents            :integer          default(0), not null
#  issued_at                      :datetime
#  other_money_cents              :integer          default(0), not null
#  purchased_from                 :string
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  organization_id                :integer
#  storage_location_id            :integer
#  vendor_id                      :integer
#

class Purchase < ApplicationRecord
  include MoneyRails::ActionViewExtension

  belongs_to :organization
  belongs_to :storage_location
  belongs_to :vendor

  include Itemizable
  include Filterable
  include IssuedAt
  include Exportable

  monetize :amount_spent_in_cents, as: :amount_spent
  monetize :amount_spent_on_diapers_cents
  monetize :amount_spent_on_adult_incontinence_cents
  monetize :amount_spent_on_other_cents

  scope :at_storage_location, ->(storage_location_id) {
                                where(storage_location_id: storage_location_id)
                              }
  scope :from_vendor, ->(vendor_id) {
    where(vendor_id: vendor_id)
  }
  scope :purchased_from, ->(purchased_from) { where(purchased_from: purchased_from) }
  scope :during, ->(range) { where(purchases: { issued_at: range }) }
  scope :recent, ->(count = 3) { order(issued_at: :desc).limit(count) }
  scope :for_csv_export, ->(organization, *) {
    where(organization: organization)
      .includes(:line_items, :storage_location)
      .order(created_at: :desc)
  }

  scope :active, -> { joins(:line_items).joins(:items).where(items: { active: true }) }

  before_create :combine_duplicates

  validates :amount_spent_in_cents, numericality: { greater_than: 0 }
  validate :total_equal_to_all_categories

  def storage_view
    storage_location.nil? ? "N/A" : storage_location.name
  end

  def purchased_from_view
    vendor.nil? ? purchased_from : vendor.business_name
  end

  # @return [Integer]
  def amount_spent_in_dollars
    amount_spent.dollars.to_i
  end

  def remove(item)
    # doing this will handle either an id or an object
    item_id = item.to_i
    line_item = line_items.find_by(item_id: item_id)
    line_item&.destroy
  end

  def replace_increase!(new_purchase_params)
    old_data = to_a
    item_ids = line_items_attributes(new_purchase_params).map { |i| i[:item_id].to_i }
    original_storage_location = storage_location

    ActiveRecord::Base.transaction do
      line_items.map(&:destroy!)
      reload
      Item.reactivate(item_ids)
      line_items_attributes(new_purchase_params).map { |i| i.delete(:id) }

      update! new_purchase_params

      # Roll back distribution output by increasing storage location
      storage_location.increase_inventory(to_a)
      # Apply the new changes to the storage location inventory
      original_storage_location.decrease_inventory(old_data)
      # TODO: Discuss this -- *should* we be removing InventoryItems when they hit 0 count?
      original_storage_location.inventory_items.where(quantity: 0).destroy_all
    end
  rescue ActiveRecord::RecordInvalid
    false
  end

  def self.csv_export_headers
    ["Purchases from", "Storage Location", "Purchased Date", "Quantity of Items", "Variety of Items", "Amount Spent"]
  end

  def csv_export_attributes
    [
      purchased_from_view,
      storage_location.name,
      issued_at.strftime("%Y-%m-%d"),
      line_items.total,
      line_items.size,
      amount_spent_in_dollars
    ]
  end

  private

  def combine_duplicates
    Rails.logger.info "[!] Purchase.combine_duplicates: Combining!"
    line_items.combine!
  end

  def total_equal_to_all_categories
    return if amount_spent.zero?
    return if amount_spent_on_diapers.zero? && amount_spent_on_adult_incontinence.zero? && amount_spent_on_other.zero?

    category_total = amount_spent_on_diapers + amount_spent_on_adult_incontinence + amount_spent_on_other
    if category_total != amount_spent
      cat_total = humanized_money_with_symbol(category_total)
      total = humanized_money_with_symbol(amount_spent)
      errors.add(:amount_spent,
        "does not equal all categories - categories add to #{cat_total} but given total is #{total}")
    end
  end
end
