# frozen_string_literal: true

require "test_helper"
require "apoio"

class ExecutarTest < Minitest::Test
  def setup
    @rel = RelogioFalso.new
    @freio = Freio.new(base: 2, teto: 30, fator: 2, jitter: 0,
                       relogio: @rel.relogio, dormir: @rel.sono)
  end

  def test_devolve_o_valor_do_bloco
    assert_equal 42, Freio.executar(@freio, idempotente: true) { 42 }
  end

  def test_idempotente_refaz_depois_da_pausa
    chamadas = 0
    r = Freio.executar(@freio, idempotente: true) do
      chamadas += 1
      raise Freio::Indisponivel, "503" if chamadas == 1

      :ok
    end
    assert_equal :ok, r
    assert_equal 2, chamadas
    assert_in_delta 2.0, @rel.agora, 1e-9, "a segunda tentativa só ocorre depois da pausa"
  end

  def test_sucesso_zera_backoff_depois_do_retry
    n = 0
    Freio.executar(@freio, idempotente: true) do
      n += 1
      raise Freio::Indisponivel if n == 1

      :ok
    end
    assert_equal 0, @freio.seguidas
  end

  def test_idempotente_esgota_tentativas
    chamadas = 0
    erro = assert_raises(Freio::TentativasEsgotadas) do
      Freio.executar(@freio, idempotente: true, tentativas: 3) do
        chamadas += 1
        raise Freio::Indisponivel, "503"
      end
    end
    assert_equal 3, chamadas
    assert_equal "503", erro.message
  end

  def test_tentativas_invalidas
    assert_raises(ArgumentError) { Freio.executar(@freio, tentativas: 0) { 1 } }
  end

  def test_erro_de_outra_natureza_passa_sem_acionar
    assert_raises(KeyError) { Freio.executar(@freio, idempotente: true) { raise KeyError } }
    refute @freio.pausado?
  end

  def test_retry_after_do_servidor_vira_piso
    n = 0
    Freio.executar(@freio, idempotente: true) do
      n += 1
      raise Freio::Indisponivel.new("503", retry_after: 9) if n == 1

      :ok
    end
    assert_in_delta 9.0, @rel.agora, 1e-9
  end
end
