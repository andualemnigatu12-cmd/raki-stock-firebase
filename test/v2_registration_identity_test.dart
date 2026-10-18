import 'package:flutter_test/flutter_test.dart';
import 'package:raki_stock_firebase/core/data/product_catalog_repository.dart';
import 'package:raki_stock_firebase/core/data/registration_repository.dart';

void main() {
  group('V2 registration identity', () {
    test('same barcode maps to one product ID despite label differences', () {
      final a = RegistrationRepository.productId(
        branchId: 'raki-bale-robe',
        normalizedName: ProductCatalogRepository.normalizeName('Coca Cola 500ml'),
        barcode: '5449000-123',
      );
      final b = RegistrationRepository.productId(
        branchId: 'raki-bale-robe',
        normalizedName: ProductCatalogRepository.normalizeName('Coca-Cola 500 ml'),
        barcode: '5449000123',
      );
      expect(a, b);
      expect(a, startsWith('v2-raki-bale-robe-b-'));
    });

    test('different barcodes never auto-map to one product', () {
      final a = RegistrationRepository.productId(
        branchId: 'raki-bale-robe',
        normalizedName: 'same product name',
        barcode: '111',
      );
      final b = RegistrationRepository.productId(
        branchId: 'raki-bale-robe',
        normalizedName: 'same product name',
        barcode: '222',
      );
      expect(a, isNot(b));
    });

    test('no-barcode identity separates product sizes', () {
      final a = RegistrationRepository.productId(
        branchId: 'raki-bale-robe',
        normalizedName: ProductCatalogRepository.normalizeName('Milk 500 ml'),
        barcode: '',
      );
      final b = RegistrationRepository.productId(
        branchId: 'raki-bale-robe',
        normalizedName: ProductCatalogRepository.normalizeName('Milk 1 L'),
        barcode: '',
      );
      expect(a, isNot(b));
    });

    test('keeps Ethiopic text searchable', () {
      final name = ProductCatalogRepository.normalizeName('ቡና 250 ግራም');
      expect(name, contains('ቡና'));
      expect(name, contains('250'));
      final id = RegistrationRepository.productId(
        branchId: 'raki-bale-robe',
        normalizedName: name,
        barcode: '',
      );
      expect(id, startsWith('v2-'));
    });
  });
}
