"""Part recognition model: an image backbone, a unit-length embedding, and one prototype vector per shape."""
import torch
import torch.nn as nn
import torch.nn.functional as F
import timm

MEAN, STD = (0.485, 0.456, 0.406), (0.229, 0.224, 0.225)


class PartNet(nn.Module):
    def __init__(self, backbone: str, num_classes: int, image_size: int = 224, embed_dim: int = 384, pretrained: bool = True):
        super().__init__()
        kwargs = {"img_size": image_size} if backbone.startswith(("vit", "eva", "deit")) else {}
        self.backbone = timm.create_model(backbone, pretrained=pretrained, num_classes=0, **kwargs)
        self.neck = nn.Sequential(nn.Linear(self.backbone.num_features, embed_dim), nn.BatchNorm1d(embed_dim))
        self.prototypes = nn.Parameter(torch.randn(num_classes, embed_dim) * 0.01)

    def embed(self, images):
        """Unit-length embedding. Views of one piece can be fused by adding their logits."""
        return F.normalize(self.neck(self.backbone(images)), dim=1)

    def forward(self, images):
        """Cosine similarity of each image to every shape prototype, in [-1, 1]."""
        return self.embed(images) @ F.normalize(self.prototypes, dim=1).T


def margin_loss(cosine, target, scale: float = 30.0, margin: float = 0.2):
    """CosFace: the true class must win by a margin, which pulls look-alike shapes apart."""
    return F.cross_entropy(scale * (cosine - margin * F.one_hot(target, cosine.shape[1])), target, label_smoothing=0.05)
