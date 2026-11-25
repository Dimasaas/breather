# frozen_string_literal: true

require "test_helper"
require "apoio"

class BreatherTest < Minitest::Test
  def setup
    @rel = RelogioFalso.new
  end

  def novo(**opcoes)
    Breather.new(base: 2, teto: 30, fator: 2, jitter: 0,
              relogio: @rel.relogio, dormir: @rel.sono, **opcoes)
  end

  def test_sem_pausa_aguardar_nao_espera
    breather = novo
    refute breather.aguardar!
    assert_empty @rel.sonos
    refute breather.pausado?
  end

  def test_acionar_abre_pausa_pela_base
    breather = novo
    assert_in_delta 2.0, breather.acionar!("503"), 1e-9
    assert breather.pausado?
    assert_in_delta 2.0, breather.restante, 1e-9
  end

  def test_aguardar_dorme_ate_o_fim_da_pausa
    breather = novo
    breather.acionar!
    assert breather.aguardar!
    assert_in_delta 2.0, @rel.agora, 1e-9
    refute breather.pausado?
  end

  def test_aguardar_dorme_em_fatias
    breather = novo(fatia: 0.5)
    breather.acionar!
    breather.aguardar!
    assert_equal [0.5] * 4, @rel.sonos
  end

  def test_acionar_durante_pausa_nao_escala
    breather = novo
    breather.acionar!
    assert_nil breather.acionar!("outro 503 da mesma janela")
    assert_equal 1, breather.pausas
    assert_equal 1, breather.seguidas
  end

  def test_backoff_exponencial_entre_janelas_seguidas
    breather = novo
    duracoes = 3.times.map do
      d = breather.acionar!
      breather.aguardar!
      d
    end
    assert_equal [2.0, 4.0, 8.0], duracoes
  end

  def test_sucesso_zera_o_backoff
    breather = novo
    2.times do
      breather.acionar!
      breather.aguardar!
    end
    breather.sucesso!
    assert_in_delta 2.0, breather.acionar!, 1e-9
  end

  def test_sucesso_durante_pausa_nao_zera
    breather = novo
    breather.acionar!
    breather.sucesso!
    assert_equal 1, breather.seguidas
  end

  def test_liberar_encerra_a_pausa_e_zera
    breather = novo
    breather.acionar!
    breather.liberar!
    refute breather.pausado?
    assert_equal 0, breather.seguidas
    refute breather.aguardar!
  end

  def test_espera_do_servidor_vira_piso
    breather = novo
    assert_in_delta 10.0, breather.acionar!("503", espera: 10), 1e-9
  end

  def test_espera_menor_que_a_base_nao_encurta
    breather = novo
    assert_in_delta 2.0, breather.acionar!("503", espera: 0.5), 1e-9
  end

  def test_ao_acionar_recebe_motivo_e_duracao
    visto = []
    breather = novo(ao_acionar: ->(motivo, d) { visto << [motivo, d] })
    breather.acionar!("HTTP 503")
    breather.acionar!("repetido")
    assert_equal [["HTTP 503", 2.0]], visto
  end

  def test_parametros_invalidos
    assert_raises(ArgumentError) { Breather.new(base: 0) }
    assert_raises(ArgumentError) { Breather.new(base: 5, teto: 1) }
    assert_raises(ArgumentError) { Breather.new(fator: 0.5) }
    assert_raises(ArgumentError) { Breather.new(jitter: 1.5) }
    assert_raises(ArgumentError) { Breather.new(fatia: 0) }
  end
end
