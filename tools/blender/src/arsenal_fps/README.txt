ARSENAL FPS — QUATRO ARMAS GENÉRICAS

Oito GLBs: quatro view models com braços e quatro pickups sem braços.
Fontes Blender, texturas externas, prévias e relatórios incluídos.
Sem marcas ou logotipos reais. Modelos originais construídos para este pacote.

ARQUIVOS E TRIÂNGULOS (incluem geometria dos acessórios animados)
pistol_9mm_viewmodel.glb     24.916
carbine_556_viewmodel.glb    29.760
revolver_38_viewmodel.glb    26.080
shotgun_12g_viewmodel.glb    25.348
pistol_9mm_pickup.glb         8.972
carbine_556_pickup.glb       13.624
revolver_38_pickup.glb        9.520
shotgun_12g_pickup.glb       10.436

COORDENADAS E CÂMERA
Metros, +Y acima. ViewRoot na origem da câmera, olhando -Z.
Prévias em 1920 x 1080, FOV HORIZONTAL de 70 graus. Para motor que usa
FOV vertical, o equivalente em 16:9 é aproximadamente 43 graus.
Armas ocupam a região inferior direita; os braços saem pela borda inferior.
O enquadramento deve ser mantido ao importar: não recentrar os view models.
Nenhuma geometria fica atrás da câmera, inclusive durante os quatro clipes.
Os pickups têm origem no centro do volume da arma, sem mãos ou rig.

MATERIAIS
Duas superfícies PBR nos view models: Arms_shared_2048 e Weapon_2048.
Um atlas 2048 por superfície, com basecolor, normal e metallic_roughness.
O conjunto arms_shared é idêntico nos quatro GLBs, conferido por SHA256;
o jogo pode compartilhar essas imagens em memória. Cada arma tem atlas próprio.
Pickups usam somente as três imagens de sua arma. Tudo incorporado nos GLBs.
Normal tangente OpenGL (+Y); G = roughness; B = metallic. Sem emissivos.
UVs de atlas utilizam regiões reutilizadas para peças do mesmo acabamento.

RIG
Um esqueleto por view model. Nomes obrigatórios:
ViewRoot, LeftUpperArm, LeftForeArm, LeftHand, RightUpperArm, RightForeArm,
RightHand, Weapon, Magazine, SpareMagazine, Bolt.
Trinta ossos de dedos: Left/RightHand + Thumb/Index/Middle/Ring/Pinky + 1/2/3.
Total 41 ossos; revólver acrescenta Speedloader e Ejector, total 43.
Os dedos têm pesos de skin e podem ser ajustados no Blender.
Mão de apoio sob o guarda-mão/telha, palma para cima, polegar à esquerda,
dedos envolvendo o lado direito. Armas curtas usam apoio da mão esquerda
sobre a empunhadura da direita. Indicador direito ao longo da arma em repouso;
flexiona durante fire. As poses são originais, sem dependência de Mixamo.

ANIMAÇÕES — 30 FPS, ROOT MOTION DESLIGADO
Todos: idle 1,6 s (loop); draw 0,4 s (uma vez).
Pistola: fire 0,2 s; reload 2,1 s.
Carabina: fire 0,2 s; reload 2,4 s.
Revólver: fire 0,3 s; reload 2,5 s.
Escopeta: fire 0,6 s; reload 2,5 s.
Somente idle tem animation.extras.loop=true. Os outros são one-shot.

A pistola tem slide móvel, troca de carregador e ação de recarga do slide.
A carabina troca o carregador e aciona o mecanismo do ferrolho.
O revólver abre o tambor lateralmente, ejeta as cápsulas, insere seis cartuchos
com carregador rápido, retira o carregador e fecha o tambor.
A escopeta tem recuo, movimento da telha no fire e inserção de dois cartuchos
soltos pelo portão inferior no reload. Magazine é reservado e vazio na escopeta;
SpareMagazine representa o cartucho solto manipulado pela mão de apoio.

Os acessórios fora de uso são ocultados por escala pequena, nunca por
transporte para trás da câmera. Não remova canais de escala na importação.
Magazine e SpareMagazine alternam a representação do carregador/cartuchos
na conclusão da inserção. As animações são visuais e não implementam
munição, projéteis, colisão, som ou efeitos de disparo no motor.

FONTES E PRÉVIAS
Fontes Blender contêm os materiais e imagens empacotadas, sem câmeras,
luzes ou chão. Os clipes ficam disponíveis nos dados de animação/NLA.
As prévias *_camera_grip são da câmera exata de 70 graus; os demais ângulos
mostram os mecanismos para inspeção. Iluminação e fundo são só das prévias.

VALIDAÇÃO
Relatórios em validation: triângulos, geometria finita, normais e tangentes,
UVs no quadrado 0-1, texturas, pesos normalizados, dedos, frames de todos
os clipes, câmera e atlas compartilhado. Fontes Blender verificadas à parte.
Khronos Validator: zero erros, zero avisos e zero informações nos oito GLBs.
