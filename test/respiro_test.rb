# frozen_string_literal: true

require "test_helper"
require "apoio"

class RespiroTest < Minitest::Test
  def setup
    @rel = RelogioFalso.new
  end

  def novo(**opcoes)
    Respiro.new(base: 2, teto: 30, fator: 2, jitter: 0,
              relogio: @rel.relogio, dormir: @rel.sono, **opcoes)
  end

  def test_sem_pausa_aguardar_nao_espera
    respiro = novo
    refute respiro.aguardar!
    assert_empty @rel.sonos
    refute respiro.pausado?
  end

  def test_acionar_abre_pausa_pela_base
    respiro = novo
    assert_in_delta 2.0, respiro.acionar!("503"), 1e-9
    assert respiro.pausado?
    assert_in_delta 2.0, respiro.restante, 1e-9
  end

  def test_aguardar_dorme_ate_o_fim_da_pausa
    respiro = novo
    respiro.acionar!
    assert respiro.aguardar!
    assert_in_delta 2.0, @rel.agora, 1e-9
    refute respiro.pausado?
  end

  def test_aguardar_dorme_em_fatias
    respiro = novo(fatia: 0.5)
    respiro.acionar!
    respiro.aguardar!
    assert_equal [0.5] * 4, @rel.sonos
  end

  def test_acionar_durante_pausa_nao_escala
    respiro = novo
    respiro.acionar!
    assert_nil respiro.acionar!("outro 503 da mesma janela")
    assert_equal 1, respiro.pausas
    assert_equal 1, respiro.seguidas
  end

  def test_backoff_exponencial_entre_janelas_seguidas
    respiro = novo
    duracoes = 3.times.map do
      d = respiro.acionar!
      respiro.aguardar!
      d
    end
    assert_equal [2.0, 4.0, 8.0], duracoes
  end

  def test_sucesso_zera_o_backoff
    respiro = novo
    2.times do
      respiro.acionar!
      respiro.aguardar!
    end
    respiro.sucesso!
    assert_in_delta 2.0, respiro.acionar!, 1e-9
  end

  def test_sucesso_durante_pausa_nao_zera
    respiro = novo
    respiro.acionar!
    respiro.sucesso!
    assert_equal 1, respiro.seguidas
  end

  def test_liberar_encerra_a_pausa_e_zera
    respiro = novo
    respiro.acionar!
    respiro.liberar!
    refute respiro.pausado?
    assert_equal 0, respiro.seguidas
    refute respiro.aguardar!
  end

  def test_espera_do_servidor_vira_piso
    respiro = novo
    assert_in_delta 10.0, respiro.acionar!("503", espera: 10), 1e-9
  end

  def test_espera_menor_que_a_base_nao_encurta
    respiro = novo
    assert_in_delta 2.0, respiro.acionar!("503", espera: 0.5), 1e-9
  end

  def test_ao_acionar_recebe_motivo_e_duracao
    visto = []
    respiro = novo(ao_acionar: ->(motivo, d) { visto << [motivo, d] })
    respiro.acionar!("HTTP 503")
    respiro.acionar!("repetido")
    assert_equal [["HTTP 503", 2.0]], visto
  end

  def test_parametros_invalidos
    assert_raises(ArgumentError) { Respiro.new(base: 0) }
    assert_raises(ArgumentError) { Respiro.new(base: 5, teto: 1) }
    assert_raises(ArgumentError) { Respiro.new(fator: 0.5) }
    assert_raises(ArgumentError) { Respiro.new(jitter: 1.5) }
    assert_raises(ArgumentError) { Respiro.new(fatia: 0) }
  end
end
