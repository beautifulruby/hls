# frozen_string_literal: true

# Rails::Generators::Testing::Assertions calls minitest's assert /
# assert_equal / assert_match under the hood. RSpec doesn't have those,
# so we shim them onto matching `expect` calls. Lets us use Rails's
# assert_file (and its block form that yields file contents) inside
# RSpec example groups.
module MinitestShims
  def assert(condition, message = nil)
    expect(condition).to(be_truthy, message)
  end

  def assert_equal(expected, actual, message = nil)
    expect(actual).to(eq(expected), message)
  end

  def assert_match(pattern, string, message = nil)
    expect(string).to(match(pattern), message)
  end

  def assert_no_match(pattern, string, message = nil)
    expect(string).not_to(match(pattern), message)
  end

  def refute(condition, message = nil)
    expect(condition).to(be_falsey, message)
  end

  def assert_nothing_raised
    yield
  end
end
