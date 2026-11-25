# frozen_string_literal: true

require "test_helper"
require "apoio"

class BordasTest < Minitest::Test
  def setup
    @rel = RelogioFalso.new
  end

  def novo(**opcoes)
    padrao = { base: 1, teto: 5, fator: 10, jitter: 0, relogio: @rel.relogio, dormir: @rel.sono }
    Freio.new(**padrao, **opcoes)
  end

  # --- teto ---------------------------------------------------------------

  def test_teto_limita_o_backoff
    freio = novo
    duracoes = 4.times.map do
      d = freio.acionar!
      freio.aguardar!
      d
    end
    assert_equal [1.0, 5.0, 5.0, 5.0], duracoes
  end

  def test_teto_limita_o_retry_after_do_servidor
    assert_in_delta 5.0, novo.acionar!("503", espera: 3600), 1e-9
  end

  def test_teto_vale_depois_do_jitter
    freio = novo(base: 4, teto: 5, jitter: 1.0, sorteio: -> { 1.0 })
    assert_in_delta 5.0, freio.acionar!, 1e-9
  end

  def test_fator_um_mantem_a_pausa_constante
    freio = novo(fator: 1, teto: 50)
    assert_equal [1.0, 1.0, 1.0], 3.times.map { freio.acionar!.tap { freio.aguardar! } }
  end

  # --- jitter -------------------------------------------------------------

  def test_jitter_soma_fracao_sorteada
    freio = novo(base: 10, teto: 100, jitter: 0.2, sorteio: -> { 0.5 })
    assert_in_delta 11.0, freio.acionar!, 1e-9
  end

  def test_jitter_zero_e_deterministico
    freio = novo(base: 10, teto: 100, jitter: 0, sorteio: -> { 0.99 })
    assert_in_delta 10.0, freio.acionar!, 1e-9
  end

  def test_jitter_fica_na_faixa_com_sorteio_real
    200.times do
      freio = novo(base: 10, teto: 100, jitter: 0.3)
      d = freio.acionar!
      assert_operator d, :>=, 10.0
      assert_operator d, :<=, 13.0
    end
  end

  def test_jitter_aplica_sobre_o_backoff_ja_escalado
    freio = novo(base: 2, teto: 100, fator: 2, jitter: 0.5, sorteio: -> { 1.0 })
    assert_in_delta 3.0, freio.acionar!, 1e-9
    freio.aguardar!
    assert_in_delta 6.0, freio.acionar!, 1e-9
  end

  # --- operacao nao idempotente -------------------------------------------

  def test_escrita_nunca_e_refeita
    freio = novo
    chamadas = 0
    erro = assert_raises(Freio::Indisponivel) do
      Freio.executar(freio, idempotente: false) do
        chamadas += 1
        raise Freio::Indisponivel, "503"
      end
    end
    assert_equal 1, chamadas
    refute_kind_of Freio::TentativasEsgotadas, erro
  end

  def test_idempotente_e_o_padrao_seguro_falso
    chamadas = 0
    assert_raises(Freio::Indisponivel) do
      Freio.executar(novo) do
        chamadas += 1
        raise Freio::Indisponivel
      end
    end
    assert_equal 1, chamadas, "sem declarar idempotente, não há retentativa"
  end

  def test_escrita_que_falha_aciona_o_freio_para_as_outras_threads
    freio = novo
    assert_raises(Freio::Indisponivel) do
      Freio.executar(freio, idempotente: false) { raise Freio::Indisponivel }
    end
    assert freio.pausado?, "a leitura que vier depois espera"
  end

  def test_escrita_tambem_espera_a_pausa_antes_de_enviar
    freio = novo
    freio.acionar!
    enviado_em = nil
    Freio.executar(freio, idempotente: false) { enviado_em = @rel.agora }
    assert_in_delta 1.0, enviado_em, 1e-9
  end

  def test_escrita_bem_sucedida_zera_o_backoff
    freio = novo
    freio.acionar!
    freio.aguardar!
    Freio.executar(freio) { :gravado }
    assert_equal 0, freio.seguidas
  end

  # --- erros e ruido ------------------------------------------------------

  def test_retry_after_negativo_ou_zero_e_ignorado_pelo_piso
    assert_in_delta 1.0, novo.acionar!("503", espera: 0), 1e-9
  end

  def test_excecao_no_bloco_nao_deixa_pausa_presa
    freio = novo
    assert_raises(RuntimeError) { Freio.executar(freio, idempotente: true) { raise "bug" } }
    refute freio.pausado?
  end
end
