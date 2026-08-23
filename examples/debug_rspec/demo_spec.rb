# frozen_string_literal: true

# debug-rspec demo: two "runtime-state" bugs that are hard to see in code
# but obvious when you can inspect the paused process.
#
# 1) Stale memoization  -> assertion failure (ExpectationNotMetError)
# 2) Never-assigned ivar -> runtime error (NoMethodError)
#
# NOTE: This file is intentionally broken — it is the demo target.
# An AI agent connected via debug-mcp diagnosed and fixed both bugs
# in the 2026-07-05 E2E run (see README.md).

class Cart
  attr_reader :items

  def initialize
    @items = []
  end

  def add(price:, qty:)
    @items << { price: price, qty: qty }
  end

  def total
    # BUG 1: memoized on first call, never invalidated by #add
    @total ||= @items.sum { |i| i[:price] * i[:qty] }
  end

  def summary
    # BUG 2: @coupon is never assigned anywhere
    "#{@items.size} items, coupon: #{@coupon.code}"
  end
end

RSpec.describe Cart do
  it "updates total when items are added" do
    cart = Cart.new
    cart.add(price: 100, qty: 2)
    expect(cart.total).to eq(200)

    cart.add(price: 50, qty: 1)
    expect(cart.total).to eq(250) # fails: total is memoized at 200
  end

  it "builds a summary" do
    cart = Cart.new
    cart.add(price: 100, qty: 1)
    expect(cart.summary).to include("1 items")
  end
end
