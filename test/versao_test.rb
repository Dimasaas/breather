# frozen_string_literal: true

require "test_helper"

class VersaoTest < Minitest::Test
  def test_versao_definida
    assert_match(/\A\d+\.\d+\.\d+\z/, Respiro::VERSION)
  end
end
