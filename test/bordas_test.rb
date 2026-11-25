# frozen_string_literal: true

require "test_helper"
require "apoio"

class BordasTest < Minitest::Test
  def setup
    @rel = RelogioFalso.new
  end

  def novo(**opcoes)
    padrao = { base: 1, teto: 5, fator: 10, jitter: 0, relogio: @rel.relogio, dormir: @rel.sono }
    Respiro.new(**padrao, **opcoes)
  end

  # --- teto ---------------------------------------------------------------

  def test_teto_limita_o_backoff
    respiro = novo
    duracoes = 4.times.map do
      d = respiro.acionar!
      respiro.aguardar!
      d
    end
    assert_equal [1.0, 5.0, 5.0, 5.0], duracoes
  end

  def test_teto_limita_o_retry_after_do_servidor
    assert_in_delta 5.0, novo.acionar!("503", espera: 3600), 1e-9
  end

  def test_teto_vale_depois_do_jitter
    respiro = novo(base: 4, teto: 5, jitter: 1.0, sorteio: -> { 1.0 })
    assert_in_delta 5.0, respiro.acionar!, 1e-9
  end

  def test_fator_um_mantem_a_pausa_constante
    respiro = novo(fator: 1, teto: 50)
    assert_equal [1.0, 1.0, 1.0], 3.times.map { respiro.acionar!.tap { respiro.aguardar! } }
  end

  # --- jitter -------------------------------------------------------------

  def test_jitter_soma_fracao_sorteada
    respiro = novo(base: 10, teto: 100, jitter: 0.2, sorteio: -> { 0.5 })
    assert_in_delta 11.0, respiro.acionar!, 1e-9
  end

  def test_jitter_zero_e_deterministico
    respiro = novo(base: 10, teto: 100, jitter: 0, sorteio: -> { 0.99 })
    assert_in_delta 10.0, respiro.acionar!, 1e-9
  end

  def test_jitter_fica_na_faixa_com_sorteio_real
    200.times do
      respiro = novo(base: 10, teto: 100, jitter: 0.3)
      d = respiro.acionar!
      assert_operator d, :>=, 10.0
      assert_operator d, :<=, 13.0
    end
  end

  def test_jitter_aplica_sobre_o_backoff_ja_escalado
    respiro = novo(base: 2, teto: 100, fator: 2, jitter: 0.5, sorteio: -> { 1.0 })
    assert_in_delta 3.0, respiro.acionar!, 1e-9
    respiro.aguardar!
    assert_in_delta 6.0, respiro.acionar!, 1e-9
  end

  # --- operacao nao idempotente -------------------------------------------

  def test_escrita_nunca_e_refeita
    respiro = novo
    chamadas = 0
    erro = assert_raises(Respiro::Indisponivel) do
      Respiro.executar(respiro, idempotente: false) do
        chamadas += 1
        raise Respiro::Indisponivel, "503"
      end
    end
    assert_equal 1, chamadas
    refute_kind_of Respiro::TentativasEsgotadas, erro
  end

  def test_idempotente_e_o_padrao_seguro_falso
    chamadas = 0
    assert_raises(Respiro::Indisponivel) do
      Respiro.executar(novo) do
        chamadas += 1
        raise Respiro::Indisponivel
      end
    end
    assert_equal 1, chamadas, "sem declarar idempotente, não há retentativa"
  end

  def test_escrita_que_falha_aciona_o_respiro_para_as_outras_threads
    respiro = novo
    assert_raises(Respiro::Indisponivel) do
      Respiro.executar(respiro, idempotente: false) { raise Respiro::Indisponivel }
    end
    assert respiro.pausado?, "a leitura que vier depois espera"
  end

  def test_escrita_tambem_espera_a_pausa_antes_de_enviar
    respiro = novo
    respiro.acionar!
    enviado_em = nil
    Respiro.executar(respiro, idempotente: false) { enviado_em = @rel.agora }
    assert_in_delta 1.0, enviado_em, 1e-9
  end

  def test_escrita_bem_sucedida_zera_o_backoff
    respiro = novo
    respiro.acionar!
    respiro.aguardar!
    Respiro.executar(respiro) { :gravado }
    assert_equal 0, respiro.seguidas
  end

  # --- erros e ruido ------------------------------------------------------

  def test_retry_after_negativo_ou_zero_e_ignorado_pelo_piso
    assert_in_delta 1.0, novo.acionar!("503", espera: 0), 1e-9
  end

  def test_excecao_no_bloco_nao_deixa_pausa_presa
    respiro = novo
    assert_raises(RuntimeError) { Respiro.executar(respiro, idempotente: true) { raise "bug" } }
    refute respiro.pausado?
  end
end
